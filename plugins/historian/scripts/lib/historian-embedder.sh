#!/usr/bin/env bash
# Embedder client for Historian.
#
# Per ADR-001, the default backend is local ollama with the
# `nomic-embed-text` model. The interface is intentionally a single
# function that takes a string and returns a JSON array of floats, so
# alternate backends (fastembed sidecar, remote API) can drop in later
# without changing callers.
#
# Fail-soft: returns empty string on any failure (ollama not reachable,
# JSON decode error, missing curl). Callers treat empty as "no vector".
#
# FAIL-SOFT IS NOT THE SAME AS FAIL-SILENT, and this file used to conflate
# them. Every failure path returned an empty string and said nothing, so a
# request that timed out, a body the server rejected, and a backend that was
# never configured were indistinguishable to the caller — which then wrote the
# chunk with no vector and emitted nothing either. Since the retriever is
# embedding-only, those chunks are persisted and unreachable. Measured on a
# real 8.5MB transcript, 4 of 93 chunks were lost this way while
# historian.indexing.complete reported outcome "ok" (ONL-123).
#
# So each path now records WHY. The reason travels on STDOUT rather than in a
# variable, and that is not a style choice: callers capture the vector with
# `$(...)`, which runs the function in a subshell, so a global assigned inside
# is discarded the moment it returns. A reason that cannot reach its caller is
# no better than no reason. historian_embedder_embed_reported prints
# "<reason>\t<detail>" on the first line and the vector on the rest;
# historian_embedder_embed keeps the old vector-only contract for callers that
# do not care why.

# Set by the internal embed path, read by the two public wrappers below. These
# only survive within a single shell, which is why nothing outside this file
# should read them — use historian_embedder_embed_reported instead.
#
# One of the historian.embedder.failed `reason` enum values, "ok" when a
# vector was produced, or "" when nothing was attempted (backend off, empty
# input).
HISTORIAN_EMBEDDER_LAST_REASON=""
# Free-text detail for the same call — curl's exit code, a size, an HTTP
# status. Goes into error_summary so a reason enum stays narrow.
HISTORIAN_EMBEDDER_LAST_DETAIL=""
# The vector the internal path produced. A global rather than stdout so its
# caller can read it without a subshell.
HISTORIAN_EMBEDDER_LAST_VECTOR=""

_historian_embedder_fail() {
	HISTORIAN_EMBEDDER_LAST_REASON="$1"
	HISTORIAN_EMBEDDER_LAST_DETAIL="${2:-}"
	return 0
}

# Resolve config (the caller has typically run historian_config_load
# before invoking us). We re-read the config knobs here so this lib can
# be sourced and used outside the SessionEnd hook context.

_historian_embedder_backend() {
	local v
	v=$(historian_config_get '.historian.embedder.backend' 2>/dev/null)
	[[ -z "$v" ]] && v="none"
	printf '%s' "$v"
}

_historian_embedder_ollama_host() {
	local v
	v=$(historian_config_get '.historian.embedder.ollama.host' 2>/dev/null)
	[[ -z "$v" ]] && v="http://127.0.0.1:11434"
	printf '%s' "$v"
}

_historian_embedder_ollama_model() {
	local v
	v=$(historian_config_get '.historian.embedder.ollama.model' 2>/dev/null)
	[[ -z "$v" ]] && v="nomic-embed-text"
	printf '%s' "$v"
}

_historian_embedder_ollama_timeout() {
	local v
	v=$(historian_config_get '.historian.embedder.ollama.request_timeout_seconds' 2>/dev/null)
	[[ -z "$v" || "$v" == "null" ]] && v=8
	printf '%s' "$v"
}

# How long ollama should keep the model resident after a request. Its own
# default is 5 minutes, which means any session starting more than five
# minutes after the last embed pays a cold load — measured at 11.24s against
# an 8s request timeout, so it fails, and fails without producing anything.
# Holding the model longer is the cheapest half of fixing that: it costs
# nothing when the model is already loaded, and it turns "every session after
# a short break is cold" into "only the first one is".
_historian_embedder_ollama_keep_alive() {
	local v
	v=$(historian_config_get '.historian.embedder.ollama.keep_alive' 2>/dev/null)
	[[ -z "$v" || "$v" == "null" ]] && v="30m"
	printf '%s' "$v"
}

# Longest body worth sending. nomic-embed-text has roughly a 2048-token
# context and answers HTTP 500 above about 7k characters; 2000 chars embed
# fine, 13000 do not. The chunker splits turns to fit, so this is a backstop
# for a raised chunk_target_chars or a model with a smaller window — without
# it those come back as a bare HTTP 500 that reads like a server fault.
_historian_embedder_max_chars() {
	historian_config_int '.historian.embedder.max_input_chars' 6000
}

# Public read of the same limit, for callers that must fit text to it *before*
# embedding rather than learn about it from a failure. The comment above assumes
# the chunker is upstream of every embed; the retrieval query has nothing
# upstream of it, so the prompt path reads this and truncates (ONL-131).
historian_embedder_max_input_chars() {
	_historian_embedder_max_chars
}

# Returns 0 if the currently-configured embedder is reachable AND the
# target model is installed. A side-effect-free probe.
#
# NOTE: this probe cannot tell you that an embed will succeed. It asks
# /api/tags, which answers instantly from disk whether or not the model is
# resident in memory. A cold daemon passes this check and then times out on
# every actual embed — which is exactly the state that produced ONL-123's
# 0-of-37 run. Treat a pass as "worth trying", not "will work".
historian_embedder_available() {
	local backend
	backend=$(_historian_embedder_backend)
	case "$backend" in
		none|"")
			return 1
			;;
		ollama)
			command -v curl >/dev/null 2>&1 || return 1
			local host model timeout tags
			host=$(_historian_embedder_ollama_host)
			model=$(_historian_embedder_ollama_model)
			timeout=$(_historian_embedder_ollama_timeout)
			# Fetch the model list and verify the configured model is present.
			# An empty models list (ollama running but no models pulled) returns 1.
			tags=$(curl -fsS --max-time "$timeout" "${host}/api/tags" 2>/dev/null) || return 1
			printf '%s' "$tags" | jq -e --arg m "$model" \
				'.models[]? | select(.name == $m or (.name | startswith($m + ":")))' \
				>/dev/null 2>&1
			;;
		*)
			# fastembed / remote backends not implemented yet — treat as
			# unavailable.
			return 1
			;;
	esac
}

# Load the model without waiting for it. Detached on purpose: a cold load
# measured 11.24s, past any hook's budget and past the request timeout, so
# there is nothing useful to do but start it and let the NEXT caller find it
# resident. Returns immediately and always succeeds.
historian_embedder_warm() {
	local backend host model keep_alive payload
	backend=$(_historian_embedder_backend)
	[[ "$backend" != "ollama" ]] && return 0
	command -v curl >/dev/null 2>&1 || return 0

	host=$(_historian_embedder_ollama_host)
	model=$(_historian_embedder_ollama_model)
	keep_alive=$(_historian_embedder_ollama_keep_alive)
	payload=$(jq -cn --arg model "$model" --arg ka "$keep_alive" \
		'{ model: $model, prompt: "warm", keep_alive: $ka }') || return 0

	# setsid so ending the session does not SIGHUP the load mid-flight;
	# nohup alone on macOS, where setsid is absent. Same reasoning as
	# scribe-stop.sh's launcher.
	if command -v setsid >/dev/null 2>&1; then
		nohup setsid curl -fsS --max-time 120 \
			-H 'Content-Type: application/json' \
			-d "$payload" "${host}/api/embeddings" >/dev/null 2>&1 &
	else
		nohup curl -fsS --max-time 120 \
			-H 'Content-Type: application/json' \
			-d "$payload" "${host}/api/embeddings" >/dev/null 2>&1 &
	fi
	disown 2>/dev/null || true
	return 0
}

# Embed a single string, reporting why if it failed.
#
# Prints "<reason>\t<detail>" on the first line, then the vector (possibly
# empty) on the rest. Use this wherever the outcome needs to be reported;
# historian_embedder_embed below is the vector-only form.
# Usage: historian_embedder_embed_reported <text>
historian_embedder_embed_reported() {
	_historian_embedder_run "${1:-}"
	printf '%s\t%s\n%s' \
		"$HISTORIAN_EMBEDDER_LAST_REASON" \
		"$HISTORIAN_EMBEDDER_LAST_DETAIL" \
		"$HISTORIAN_EMBEDDER_LAST_VECTOR"
}

# Embed a single string. Prints a JSON array of floats on success
# (e.g. `[0.123,0.456,...]`), or empty string on any error.
# Usage: historian_embedder_embed <text>
historian_embedder_embed() {
	_historian_embedder_run "${1:-}"
	printf '%s' "$HISTORIAN_EMBEDDER_LAST_VECTOR"
}

# Split what historian_embedder_embed_reported printed into
# HISTORIAN_EMBEDDER_REASON / _DETAIL / _VECTOR.
#
# Call this rather than slicing the string yourself. `$(...)` strips trailing
# newlines, so when the vector is empty the separating newline disappears with
# it and a naive "${result#*<newline>}" returns the REASON LINE as the vector —
# a non-empty string that is not a vector at all, which is worse than the empty
# one it replaced. Presence of a newline is therefore the test for whether a
# vector exists.
#
# Sets globals, so call it directly and not inside a subshell.
historian_embedder_parse() {
	local result="${1:-}" head
	if [[ "$result" == *$'\n'* ]]; then
		head="${result%%$'\n'*}"
		HISTORIAN_EMBEDDER_VECTOR="${result#*$'\n'}"
	else
		head="$result"
		HISTORIAN_EMBEDDER_VECTOR=""
	fi
	HISTORIAN_EMBEDDER_REASON="${head%%$'\t'*}"
	if [[ "$head" == *$'\t'* ]]; then
		HISTORIAN_EMBEDDER_DETAIL="${head#*$'\t'}"
	else
		HISTORIAN_EMBEDDER_DETAIL=""
	fi
}

# Internal: dispatch on backend, leaving the outcome in the globals above.
# Assigns rather than prints, so its callers need no subshell.
_historian_embedder_run() {
	local text="${1:-}"
	HISTORIAN_EMBEDDER_LAST_REASON=""
	HISTORIAN_EMBEDDER_LAST_DETAIL=""
	HISTORIAN_EMBEDDER_LAST_VECTOR=""

	# Not a failure: there is nothing to embed. Leaves the reason empty so
	# callers do not count it as an attempt.
	[[ -z "$text" ]] && return 0

	local backend
	backend=$(_historian_embedder_backend)
	case "$backend" in
		none|"")
			# Deliberately off, not broken. No reason recorded.
			return 0
			;;
		ollama)
			_historian_embedder_embed_ollama "$text"
			;;
		*)
			_historian_embedder_fail "backend_unsupported" "backend=${backend}"
			return 0
			;;
	esac
}

# Internal: call ollama's /api/embeddings endpoint.
_historian_embedder_embed_ollama() {
	local text="$1"
	if ! command -v curl >/dev/null 2>&1; then
		_historian_embedder_fail "no_curl"
		return 0
	fi

	local host model timeout keep_alive max_chars payload response rc=0
	host=$(_historian_embedder_ollama_host)
	model=$(_historian_embedder_ollama_model)
	timeout=$(_historian_embedder_ollama_timeout)
	keep_alive=$(_historian_embedder_ollama_keep_alive)
	max_chars=$(_historian_embedder_max_chars)

	# Refuse oversize locally rather than spending a request to be told HTTP
	# 500. The server's answer carries no size information, so a local check
	# is the only place the actual length can be reported.
	if (( ${#text} > max_chars )); then
		_historian_embedder_fail "oversized" "${#text} chars exceeds max_input_chars=${max_chars}"
		return 0
	fi

	payload=$(jq -cn --arg model "$model" --arg prompt "$text" --arg ka "$keep_alive" \
		'{ model: $model, prompt: $prompt, keep_alive: $ka }') || {
		_historian_embedder_fail "payload_build_failed"
		return 0
	}

	response=$(curl -fsS --max-time "$timeout" \
		-H 'Content-Type: application/json' \
		-d "$payload" \
		"${host}/api/embeddings" 2>/dev/null) || rc=$?

	if (( rc != 0 )); then
		# curl's exit codes separate causes that need different fixes: 28 is
		# our own timeout expiring (usually a cold model load), 22 is the
		# server answering with a 4xx/5xx under -f, and everything else —
		# 7 connection refused, 6 DNS, 52 empty reply — is neither.
		case "$rc" in
			28) _historian_embedder_fail "timeout" "curl exit 28 after ${timeout}s" ;;
			22) _historian_embedder_fail "http_error" "curl exit 22 (HTTP >= 400)" ;;
			*)  _historian_embedder_fail "request_failed" "curl exit ${rc}" ;;
		esac
		return 0
	fi

	if [[ -z "$response" ]]; then
		_historian_embedder_fail "empty_response"
		return 0
	fi

	# The ollama embeddings endpoint returns `{"embedding":[...]}`. Pull
	# just the array and validate it parses + is non-empty.
	local vector
	vector=$(printf '%s' "$response" | jq -c '.embedding // empty' 2>/dev/null)
	if [[ -z "$vector" || "$vector" == "null" ]]; then
		_historian_embedder_fail "no_embedding_field"
		return 0
	fi

	# Sanity: must be an array of numbers, length > 0.
	if ! printf '%s' "$vector" | jq -e '
		type == "array" and length > 0 and all(.[]; type == "number")
	' >/dev/null 2>&1; then
		_historian_embedder_fail "malformed_vector"
		return 0
	fi

	HISTORIAN_EMBEDDER_LAST_REASON="ok"
	HISTORIAN_EMBEDDER_LAST_VECTOR="$vector"
}

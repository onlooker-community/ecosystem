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
# JSON decode error, missing curl). Callers treat empty as "skip the
# embedding and emit historian.embedder.unavailable".

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

# Returns 0 if the currently-configured embedder is reachable and the
# backend is something other than "none". A side-effect-free probe.
historian_embedder_available() {
	local backend
	backend=$(_historian_embedder_backend)
	case "$backend" in
		none|"")
			return 1
			;;
		ollama)
			command -v curl >/dev/null 2>&1 || return 1
			local host timeout
			host=$(_historian_embedder_ollama_host)
			timeout=$(_historian_embedder_ollama_timeout)
			# HEAD `/api/tags` is the cheapest way to confirm the daemon
			# is up without rendering a payload.
			curl -fsS --max-time "$timeout" -o /dev/null "${host}/api/tags" 2>/dev/null
			;;
		*)
			# fastembed / remote backends not implemented yet — treat as
			# unavailable.
			return 1
			;;
	esac
}

# Embed a single string. Prints a JSON array of floats on success
# (e.g. `[0.123,0.456,...]`), or empty string on any error.
# Usage: historian_embedder_embed <text>
historian_embedder_embed() {
	local text="${1:-}"
	[[ -z "$text" ]] && return 0

	local backend
	backend=$(_historian_embedder_backend)
	case "$backend" in
		none|"")
			return 0
			;;
		ollama)
			_historian_embedder_embed_ollama "$text"
			;;
		*)
			# Backend declared but not implemented — fail-soft.
			return 0
			;;
	esac
}

# Internal: call ollama's /api/embeddings endpoint.
_historian_embedder_embed_ollama() {
	local text="$1"
	command -v curl >/dev/null 2>&1 || return 0

	local host model timeout payload response
	host=$(_historian_embedder_ollama_host)
	model=$(_historian_embedder_ollama_model)
	timeout=$(_historian_embedder_ollama_timeout)

	payload=$(jq -cn --arg model "$model" --arg prompt "$text" \
		'{ model: $model, prompt: $prompt }') || return 0

	response=$(curl -fsS --max-time "$timeout" \
		-H 'Content-Type: application/json' \
		-d "$payload" \
		"${host}/api/embeddings" 2>/dev/null) || return 0
	[[ -z "$response" ]] && return 0

	# The ollama embeddings endpoint returns `{"embedding":[...]}`. Pull
	# just the array and validate it parses + is non-empty.
	local vector
	vector=$(printf '%s' "$response" | jq -c '.embedding // empty' 2>/dev/null)
	[[ -z "$vector" || "$vector" == "null" ]] && return 0

	# Sanity: must be an array of numbers, length > 0.
	printf '%s' "$vector" | jq -e '
		type == "array" and length > 0 and all(.[]; type == "number")
	' >/dev/null 2>&1 || return 0

	printf '%s' "$vector"
}

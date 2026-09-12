#!/usr/bin/env bash
# Currency probe for the plugin-currency surfacer (ecosystem-449.59).
#
# Runs check-plugin-installs and writes the answer to the probe cache. Lives
# apart from the hook because it is run DETACHED: the live probe costs ~4.6s
# against the network, and blocking SessionStart on that would be the same
# defect ecosystem-449.43 files against scribe-stop. The hook spawns this and
# returns; the answer lands for the next session.
#
# THE EXIT-CODE CONTRACT, which is the whole reason this is separate and tested:
#   0  ran, nothing to report          -> cache the empty result
#   1  ran, FOUND SOMETHING            -> cache it; this is success, not failure
#   2  usage/setup error               -> no answer; leave the cache alone
#   124 timeout (from `timeout`)       -> no answer; leave the cache alone
# Treating 1 as failure makes the feature inert in exactly the case it exists
# for. That bug shipped once and was caught by a manual run, not by tests.
#
# On any failure the cache is left EXACTLY as it was. Restamping checked_at on
# an answer we did not re-verify is what makes a stale answer look fresh.

_PC_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/plugin-currency-cache.sh
[[ -z "${_PLUGIN_CURRENCY_CACHE_SOURCED:-}" ]] && source "${_PC_PROBE_DIR}/plugin-currency-cache.sh"

# Emit onlooker.currency.checked from the detached process. Best-effort: a probe
# that ran correctly must not fail because the bus was unavailable.
_plugin_currency_probe_emit() {
	local outcome="$1" duration="$2" count="$3"
	local sid="${PLUGIN_CURRENCY_SESSION_ID:-}"
	[[ -n "$sid" ]] || return 0
	[[ -n "${ONLOOKER_DIR:-}" ]] || return 0

	local emitter="${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/onlooker-event.mjs"
	[[ -f "$emitter" ]] || return 0
	command -v node >/dev/null 2>&1 || return 0

	local payload params event
	if [[ "$outcome" == "ok" ]]; then
		payload=$(jq -cn --arg d "$duration" --arg n "$count" \
			'{probe_outcome:"ok", duration_ms:($d|tonumber), findings_count:($n|tonumber)}') || return 0
	else
		payload=$(jq -cn --arg d "$duration" \
			'{probe_outcome:"failed", duration_ms:($d|tonumber)}') || return 0
	fi
	params=$(jq -cn --arg sid "$sid" --argjson p "$payload" \
		'{plugin:"onlooker", session_id:$sid, event_type:"onlooker.currency.checked", payload:$p}') || return 0
	event=$(printf '%s' "$params" | ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="onlooker" \
		node "$emitter" emit 2>/dev/null) || return 0
	[[ -n "$event" ]] || return 0
	mkdir -p "${ONLOOKER_DIR}/logs" 2>/dev/null
	printf '%s\n' "$event" >>"${ONLOOKER_DIR}/logs/onlooker-events.jsonl" 2>/dev/null
	return 0
}

# plugin_currency_probe_run <cwd> <cache_path> <budget_seconds> [marketplace...]
# Returns 0 when the cache was written, non-zero when no answer was obtained.
plugin_currency_probe_run() {
	local cwd="${1:-}" cache="${2:-}" budget="${3:-30}"
	shift 3 2>/dev/null || true

	[[ -n "$cwd" && -n "$cache" ]] || return 2
	command -v node >/dev/null 2>&1 || return 2

	local args=(--json --project "$cwd")
	local m
	for m in "$@"; do
		[[ -n "$m" ]] && args+=(--marketplace "$m")
	done

	# `|| rc=$?` rather than a bare assignment plus `$?`: exit 1 is a NORMAL
	# outcome here, and callers running under errexit would abort on it before
	# the code could be inspected. The guard is what lets 1 be handled at all.
	local start_s; start_s=$(date -u +%s)
	local out rc=0
	if command -v timeout >/dev/null 2>&1; then
		out=$(timeout "$budget" node "${_PC_PROBE_DIR}/../lint/check-plugin-installs.mjs" "${args[@]}" 2>/dev/null) || rc=$?
	else
		out=$(node "${_PC_PROBE_DIR}/../lint/check-plugin-installs.mjs" "${args[@]}" 2>/dev/null) || rc=$?
	fi

	local duration=$(( ($(date -u +%s) - start_s) * 1000 ))

	# Only 0 and 1 mean "we got an answer". See the contract above.
	if [[ "$rc" -gt 1 ]]; then
		_plugin_currency_probe_emit "failed" "$duration" 0
		return "$rc"
	fi

	local findings
	# Map the check's finding shape onto the schema's. These are NOT the same:
	# the check emits {plugin, marketplace, head, remoteHead, lastFetchAttempt},
	# the schema wants {reason, subject, effective, available} with
	# additionalProperties:false. Caching the raw shape emitted a payload that
	# fails validation -- invisibly, because the runtime emitter fails open
	# unless ONLOOKER_VALIDATE=1 (ADR-005). Tests missed it by using fixtures
	# written to the schema rather than samples taken from the real check.
	findings=$(printf '%s' "$out" | jq -c '
		[ (.findings // [])[] | {
			reason: .reason,
			subject: (.marketplace // .plugin // "unknown"),
			effective: ((.head // .effective // "") | tostring),
			available: ((.remoteHead // .available // "") | tostring)
		} | with_entries(select(.value != "")) ]
	' 2>/dev/null) || findings=""
	# Garbage on stdout with a zero exit must not be cached as "nothing wrong".
	if [[ -z "$findings" ]]; then
		_plugin_currency_probe_emit "failed" "$duration" 0
		return 3
	fi

	plugin_currency_cache_write "$cache" "$findings" || return 4
	_plugin_currency_probe_emit "ok" "$duration" "$(printf '%s' "$findings" | jq -r 'length')"
	return 0
}

# Executed directly (the detached path) rather than sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	plugin_currency_probe_run "$@"
	exit $?
fi

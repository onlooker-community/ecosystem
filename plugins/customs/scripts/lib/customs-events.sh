#!/usr/bin/env bash
# Canonical customs.* event emission.
#
# Thin wrapper around the ecosystem plugin's onlooker-event.mjs `emit` mode,
# the same mechanism as warden-events.sh. customs.* payloads use
# additionalProperties:false and carry kind and host only - an event about a
# possible leak must never be the leak - so a payload with any other field
# fails validation and nothing is logged.
#
# Usage:
#   customs_emit_event "customs.egress.flagged" '{"tool":"Bash",...}'

_CUSTOMS_PLUGIN_NAME="customs"

# Vendored substrate resolver, located from this file's own path and tolerated
# absent - see substrate-resolve.sh, "FAIL-SOFT CALLERS", for why both.
_CUSTOMS_EVENTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_CUSTOMS_EVENTS_LIB_DIR}/substrate-resolve.sh" ]]; then
	# shellcheck source=plugins/customs/scripts/lib/substrate-resolve.sh
	source "${_CUSTOMS_EVENTS_LIB_DIR}/substrate-resolve.sh"
fi

_customs_event_js_path() {
	if [[ -n "${_ONLOOKER_EVENT_JS:-}" && -f "$_ONLOOKER_EVENT_JS" ]]; then
		printf '%s' "$_ONLOOKER_EVENT_JS"
		return 0
	fi
	local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
	local candidates=(
		"${plugin_root}/scripts/lib/onlooker-event.mjs"
		"${plugin_root}/../../scripts/lib/onlooker-event.mjs"
	)
	local c
	for c in "${candidates[@]}"; do
		[[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
	done
	# Version-ordered, not glob-ordered (ecosystem-449.35): substrate-resolve.sh
	# picks the newest installed substrate.
	local root=""
	if declare -F onlooker_resolve_substrate >/dev/null 2>&1; then
		root="$(onlooker_resolve_substrate "$plugin_root")"
	fi
	if [[ -n "$root" && -f "${root}/scripts/lib/onlooker-event.mjs" ]]; then
		printf '%s' "${root}/scripts/lib/onlooker-event.mjs"
		return 0
	fi
	return 1
}

_customs_session_id() {
	if [[ -n "${_HOOK_SESSION_ID:-}" ]]; then
		printf '%s' "$_HOOK_SESSION_ID"
		return 0
	fi
	if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		printf '%s' "$CLAUDE_SESSION_ID"
		return 0
	fi
	printf 'unknown'
}

# Emit a single customs.* event. Returns 0 on success, non-zero on failure.
customs_emit_event() {
	local event_type="${1:-}"
	local payload="${2:-}"

	[[ -z "$event_type" || -z "$payload" ]] && return 1

	local event_js
	event_js=$(_customs_event_js_path) || return 1

	local session_id
	session_id=$(_customs_session_id)

	local params
	params=$(jq -n \
		--arg plugin "$_CUSTOMS_PLUGIN_NAME" \
		--arg sid "$session_id" \
		--arg type "$event_type" \
		--argjson payload "$payload" \
		'{plugin: $plugin, session_id: $sid, event_type: $type, payload: $payload}' \
		2>/dev/null) || return 1

	local event
	local stderr_file
	stderr_file=$(mktemp -t customs-event-err.XXXXXX 2>/dev/null) || stderr_file="/tmp/customs-event-err.$$"
	event=$(printf '%s' "$params" \
		| ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}" \
		  ONLOOKER_PLUGIN_NAME="$_CUSTOMS_PLUGIN_NAME" \
		  node "$event_js" emit 2>"$stderr_file") || {
		printf 'customs_emit_event: schema validation failed for %s\n' "$event_type" >&2
		[[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
		rm -f "$stderr_file"
		return 1
	}
	rm -f "$stderr_file"

	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	mkdir -p "$(dirname "$log_path")" 2>/dev/null || return 1
	printf '%s\n' "$event" >> "$log_path"
}

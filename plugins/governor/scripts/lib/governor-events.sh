#!/usr/bin/env bash
# Canonical governor.* event emission.
#
# Thin wrapper around the ecosystem plugin's onlooker-event.mjs `emit` mode.
# Every emission is validated against @onlooker-community/schema v2.4.0+
# before being appended to ~/.onlooker/logs/onlooker-events.jsonl.
#
# Usage:
#   governor_emit_event "governor.gate.checked" '{"session_id":"...","decision":"allow",...}'

_GOVERNOR_PLUGIN_NAME="governor"

_governor_event_js_path() {
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
	return 1
}

_governor_session_id() {
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

# Emit a single governor.* event. Returns 0 on success, non-zero on failure.
governor_emit_event() {
	local event_type="${1:-}"
	local payload="${2:-}"

	[[ -z "$event_type" || -z "$payload" ]] && return 1

	local event_js
	event_js=$(_governor_event_js_path) || return 1

	local session_id
	session_id=$(_governor_session_id)

	local envelope
	envelope=$(jq -n \
		--arg et "$event_type" \
		--arg sid "$session_id" \
		--arg plugin "$_GOVERNOR_PLUGIN_NAME" \
		--argjson payload "$payload" \
		'{
			event_type: $et,
			schema_version: "1.0",
			session_id: $sid,
			plugin: $plugin,
			payload: $payload
		}' 2>/dev/null) || return 1

	local validated
	validated=$(printf '%s' "$envelope" \
		| ONLOOKER_DIR="${ONLOOKER_DIR:-}" \
		  node "$event_js" validate 2>/dev/null) \
		|| { printf 'governor_emit_event: schema validation failed for %s\n' "$event_type" >&2; return 1; }

	local log="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	mkdir -p "$(dirname "$log")" 2>/dev/null || true
	printf '%s\n' "$envelope" >> "$log" 2>/dev/null
}

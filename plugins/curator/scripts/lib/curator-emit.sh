#!/usr/bin/env bash
# Event emission helpers for Curator.
#
# Thin wrapper around onlooker-event.mjs `emit` mode for curator.* events.
# Fail-soft: returns 0 on success or when the substrate is unavailable.

_curator_resolve_event_js() {
	local script_dir plugin_root ecosystem_root candidate
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	plugin_root="$(cd "${script_dir}/../.." && pwd)"

	ecosystem_root="${ONLOOKER_ECOSYSTEM_ROOT:-}"
	if [[ -z "$ecosystem_root" ]]; then
		candidate="$(cd "${plugin_root}/../.." 2>/dev/null && pwd)"
		if [[ -f "${candidate}/scripts/lib/onlooker-event.mjs" ]]; then
			ecosystem_root="$candidate"
		fi
	fi

	if [[ -n "$ecosystem_root" ]]; then
		printf '%s/scripts/lib/onlooker-event.mjs' "$ecosystem_root"
	fi
}

_CURATOR_EVENT_JS="${_CURATOR_EVENT_JS:-$(_curator_resolve_event_js)}"

# Emit a curator.* event. Fail-soft: returns 0 on any error.
# Usage: curator_emit <event_type> <session_id> <payload_json>
curator_emit() {
	local event_type="${1:-}"
	local session_id="${2:-}"
	local payload="${3:-{\}}"

	[[ -z "$event_type" || -z "$session_id" ]] && return 0
	[[ -z "$_CURATOR_EVENT_JS" || ! -f "$_CURATOR_EVENT_JS" ]] && return 0
	command -v node >/dev/null 2>&1 || return 0
	[[ -z "${ONLOOKER_EVENTS_LOG:-}" ]] && return 0

	local params event_json
	params=$(jq -cn \
		--arg plugin "curator" \
		--arg session_id "$session_id" \
		--arg event_type "$event_type" \
		--argjson payload "$payload" \
		'{
			plugin: $plugin,
			session_id: $session_id,
			event_type: $event_type,
			payload: $payload
		}') || return 0

	event_json=$(
		ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}" \
		ONLOOKER_PLUGIN_NAME="curator" \
		printf '%s' "$params" | node "$_CURATOR_EVENT_JS" emit 2>/dev/null
	) || return 0
	[[ -z "$event_json" ]] && return 0

	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")" 2>/dev/null
	printf '%s\n' "$event_json" >> "$ONLOOKER_EVENTS_LOG" 2>/dev/null
}

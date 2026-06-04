#!/usr/bin/env bash
# Event emission helpers for Librarian.
#
# Wraps the canonical onlooker-event.mjs `emit` mode so hook scripts can
# build a librarian.* event without touching node directly. Events are
# schema-validated by onlooker-event.mjs; if validation fails the line is
# silently dropped (fail-soft) rather than blocking the hook.

# Resolve the ecosystem helper path. The substrate is in the sibling
# ecosystem plugin at ../../../.. relative to plugins/librarian/scripts/hooks.
# Honor ONLOOKER_ECOSYSTEM_ROOT when set (test isolation).
_librarian_resolve_event_js() {
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

_LIBRARIAN_EVENT_JS="${_LIBRARIAN_EVENT_JS:-$(_librarian_resolve_event_js)}"

# Emit a librarian.* event. Fail-soft: returns 0 on success or when the
# substrate is unavailable; the event is dropped silently.
#
# Usage: librarian_emit <event_type> <session_id> <payload_json>
#
# Example:
#   librarian_emit "librarian.scan.started" "$SID" "$(jq -n \
#     --arg trigger "session_end" '{ trigger: $trigger }')"
librarian_emit() {
	local event_type="${1:-}"
	local session_id="${2:-}"
	local payload="${3:-{\}}"

	[[ -z "$event_type" || -z "$session_id" ]] && return 0
	[[ -z "$_LIBRARIAN_EVENT_JS" || ! -f "$_LIBRARIAN_EVENT_JS" ]] && return 0
	command -v node >/dev/null 2>&1 || return 0
	[[ -z "${ONLOOKER_EVENTS_LOG:-}" ]] && return 0

	local params event_json
	params=$(jq -cn \
		--arg plugin "librarian" \
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
		ONLOOKER_PLUGIN_NAME="librarian" \
		printf '%s' "$params" | node "$_LIBRARIAN_EVENT_JS" emit 2>/dev/null
	) || return 0
	[[ -z "$event_json" ]] && return 0

	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")" 2>/dev/null
	printf '%s\n' "$event_json" >> "$ONLOOKER_EVENTS_LOG" 2>/dev/null
}

#!/usr/bin/env bash
# cartographer-events.sh — emit cartographer.* events to the canonical event log.
#
# Thin wrapper around onlooker-event.mjs. Validation failures are logged to
# stderr and do not abort the caller — Cartographer is advisory.
#
# Usage:
#   cartographer_emit_event "cartographer.audit.complete" '{"audit_id":"...","new_finding_count":2}'

_CARTOGRAPHER_PLUGIN_NAME="cartographer"

_cartographer_event_js_path() {
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

_cartographer_session_id() {
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

cartographer_emit_event() {
	local event_type="${1:-}"
	local payload="${2:-}"
	[[ -z "$event_type" || -z "$payload" ]] && return 1

	local event_js
	event_js=$(_cartographer_event_js_path) || {
		printf 'cartographer-events: cannot locate onlooker-event.mjs\n' >&2
		return 1
	}

	local session_id
	session_id=$(_cartographer_session_id)

	local params
	params=$(jq -n \
		--arg plugin "$_CARTOGRAPHER_PLUGIN_NAME" \
		--arg sid "$session_id" \
		--arg type "$event_type" \
		--argjson payload "$payload" \
		'{"plugin":$plugin,"session_id":$sid,"event_type":$type,"payload":$payload}')

	local stderr_file
	stderr_file=$(mktemp -t cartographer-event-err.XXXXXX 2>/dev/null) \
		|| stderr_file="/tmp/cartographer-event-err.$$"

	local event
	event=$(printf '%s' "$params" \
		| ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}" \
		  ONLOOKER_PLUGIN_NAME="$_CARTOGRAPHER_PLUGIN_NAME" \
		  node "$event_js" emit 2>"$stderr_file") || {
		printf 'cartographer-events: schema validation failed for %s\n' "$event_type" >&2
		[[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
		rm -f "$stderr_file"
		return 1
	}
	rm -f "$stderr_file"

	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	mkdir -p "$(dirname "$log_path")" 2>/dev/null || return 1
	printf '%s\n' "$event" >>"$log_path"
}

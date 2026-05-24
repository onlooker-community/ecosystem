#!/usr/bin/env bash
# Canonical tribunal.* event emission.
#
# Thin wrapper around the ecosystem plugin's onlooker-event.mjs `emit` mode.
# Every emission is validated against @onlooker-community/schema v2.1.0+ before
# it is appended to ~/.onlooker/logs/onlooker-events.jsonl.
#
# Why a per-plugin wrapper: bash hooks should not have to know about node
# invocation paths or env wiring. This module centralizes that detail so the
# orchestrator and Stop hook both call `tribunal_emit_event <type> <payload>`.
#
# Requires:
#   - $ONLOOKER_DIR (set by the ecosystem onlooker-schema.sh)
#   - $ONLOOKER_EVENTS_LOG (same)
#   - $_HOOK_SESSION_ID or $CLAUDE_SESSION_ID for the session id
#   - The ecosystem onlooker-event.mjs reachable via $_ONLOOKER_EVENT_JS or
#     under the ecosystem plugin root.
#
# Usage:
#   tribunal_emit_event "tribunal.session.start" '{"task_id":"01J...","gate_policy":"majority"}'

_TRIBUNAL_PLUGIN_NAME="tribunal"

# Resolve the ecosystem onlooker-event.mjs even when CLAUDE_PLUGIN_ROOT points
# at the tribunal plugin (the wrapper script lives under ecosystem/scripts/lib).
_tribunal_event_js_path() {
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

_tribunal_session_id() {
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

# Emit a single tribunal event. Returns 0 on success, non-zero on validation
# failure (so callers can decide whether to abort the loop). Validation errors
# are written to stderr.
tribunal_emit_event() {
	local event_type="${1:-}"
	local payload="${2:-}"
	[[ -z "$event_type" || -z "$payload" ]] && return 1

	local event_js
	event_js=$(_tribunal_event_js_path) || {
		printf 'tribunal-events: cannot locate onlooker-event.mjs\n' >&2
		return 1
	}

	local session_id
	session_id=$(_tribunal_session_id)

	local params
	params=$(jq -n \
		--arg plugin "$_TRIBUNAL_PLUGIN_NAME" \
		--arg sid "$session_id" \
		--arg type "$event_type" \
		--argjson payload "$payload" \
		'{plugin: $plugin, session_id: $sid, event_type: $type, payload: $payload}')

	local event
	local stderr_file
	stderr_file=$(mktemp -t tribunal-event-err.XXXXXX 2>/dev/null) || stderr_file="/tmp/tribunal-event-err.$$"
	event=$(printf '%s' "$params" \
		| ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}" \
		  ONLOOKER_PLUGIN_NAME="$_TRIBUNAL_PLUGIN_NAME" \
		  node "$event_js" emit 2>"$stderr_file") || {
		printf 'tribunal-events: schema validation failed for %s\n' "$event_type" >&2
		[[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
		rm -f "$stderr_file"
		return 1
	}
	rm -f "$stderr_file"

	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	mkdir -p "$(dirname "$log_path")" 2>/dev/null || return 1
	printf '%s\n' "$event" >>"$log_path"
}

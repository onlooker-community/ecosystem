#!/usr/bin/env bash
# Bash wrappers for canonical Onlooker events (@onlooker-community/schema).
# Requires validate-path.sh to be sourced first.

_ONLOOKER_EVENT_JS="${_ONLOOKER_EVENT_JS:-${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/onlooker-event.mjs}"

# Append a validated canonical event JSON line to the global events log.
# Usage: onlooker_append_event "$event_json"
onlooker_append_event() {
	local event_json="${1:-}"
	[[ -z "$event_json" ]] && return 0

	ensure_dir_exists "$(dirname "$ONLOOKER_EVENTS_LOG")" || return 1
	printf '%s\n' "$event_json" >>"$ONLOOKER_EVENTS_LOG" 2>/dev/null
}

# Build a canonical event from Claude Code hook stdin JSON (prints event or empty).
# Usage: event=$(onlooker_event_from_hook "$INPUT")
onlooker_event_from_hook() {
	local hook_input="${1:-}"
	[[ -z "$hook_input" ]] && return 0

	if [[ ! -f "$_ONLOOKER_EVENT_JS" ]]; then
		return 1
	fi

	printf '%s' "$hook_input" | ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="$ONLOOKER_PLUGIN_NAME" \
		ONLOOKER_TURN_NUMBER="${ONLOOKER_TURN_NUMBER:-}" \
		ONLOOKER_TASK_DURATION_MS="${ONLOOKER_TASK_DURATION_MS:-}" \
		ONLOOKER_WORKTREE_DURATION_MS="${ONLOOKER_WORKTREE_DURATION_MS:-}" \
		node "$_ONLOOKER_EVENT_JS" emit-from-hook 2>/dev/null
}

# Emit canonical event: validate via schema and append to events log.
# Usage: onlooker_emit_from_hook "$INPUT"
onlooker_emit_from_hook() {
	local event
	event=$(onlooker_event_from_hook "${1:-}")
	[[ -z "$event" ]] && return 0
	onlooker_append_event "$event"
}

# Validate stdin JSON against the canonical envelope; exit 0/1.
# Usage: echo "$event" | onlooker_validate_event
onlooker_validate_event() {
	[[ -f "$_ONLOOKER_EVENT_JS" ]] || return 1
	node "$_ONLOOKER_EVENT_JS" validate
}

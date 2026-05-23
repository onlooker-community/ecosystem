#!/usr/bin/env bash
# Tool history helpers — canonical session JSONL via @onlooker-community/schema.
#
# Source after validate-path.sh and onlooker-schema.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/validate-path.sh"
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/onlooker-schema.sh"
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tool-history.sh"

# Build a canonical OnlookerEvent from hook stdin (empty when unmapped).
# Usage: record=$(tool_history_build_record "$INPUT")
tool_history_build_record() {
	local input_json="${1:-}"
	onlooker_event_from_hook "$input_json"
}

# Append a canonical event to the session JSONL history (lock-protected).
# Uses the portable mkdir-based mutex so the hook works on macOS as well as
# Linux. Usage: tool_history_append "$SESSION_ID" "$event_json"
tool_history_append() {
	local session_id="${1:-}"
	local record_json="${2:-}"

	[[ -z "$session_id" || "$session_id" == "null" || -z "$record_json" ]] && return 0

	local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${session_id}.jsonl"
	ensure_dir_exists "$ONLOOKER_SESSION_HISTORY_DIR" || return 1

	local lockfile="${history_file}.lock"
	lock_acquire "$lockfile" 5 || return 1
	printf '%s\n' "$record_json" >>"$history_file" 2>/dev/null
	local rc=$?
	lock_release "$lockfile"
	return "$rc"
}

#!/usr/bin/env bash
# Task lifecycle helpers — task.start / task.complete canonical events.
#
# Source after validate-path.sh, onlooker-schema.sh, session-tracker.sh, and tool-history.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/task-tracker.sh"

# Record task creation time in the per-session tracker for duration on complete.
# Usage: task_tracker_record_created "$SESSION_ID" "$TASK_ID"
task_tracker_record_created() {
	local session_id="${1:-}"
	local task_id="${2:-}"
	[[ -z "$session_id" || "$session_id" == "null" || -z "$task_id" || "$task_id" == "null" ]] && return 0

	turn_state_ensure_session "$session_id" || return 1

	local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
	local now_ms
	now_ms=$(session_tracker_now_ms)

	local temp_file
	temp_file=$(mktemp)
	if jq --arg id "$task_id" --argjson ms "$now_ms" \
		'.tasks[$id] = {start_time_ms: $ms}' \
		"$tracker_file" >"$temp_file" 2>/dev/null; then
		mv "$temp_file" "$tracker_file"
	else
		rm -f "$temp_file"
		return 1
	fi
}

# Compute duration since task creation; prints empty when unknown.
# Usage: duration_ms=$(task_tracker_duration_ms "$SESSION_ID" "$TASK_ID")
task_tracker_duration_ms() {
	local session_id="${1:-}"
	local task_id="${2:-}"
	[[ -z "$session_id" || -z "$task_id" ]] && return 0

	local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
	[[ ! -f "$tracker_file" ]] && return 0

	local start_ms
	start_ms=$(jq -r --arg id "$task_id" '.tasks[$id].start_time_ms // empty' "$tracker_file" 2>/dev/null)
	[[ -z "$start_ms" || "$start_ms" == "null" ]] && return 0

	local now_ms elapsed
	now_ms=$(session_tracker_now_ms)
	elapsed=$((now_ms - start_ms))
	if [[ "$elapsed" -ge 0 ]]; then
		printf '%s' "$elapsed"
	fi
}

# Remove task timing entry after completion.
# Usage: task_tracker_clear "$SESSION_ID" "$TASK_ID"
task_tracker_clear() {
	local session_id="${1:-}"
	local task_id="${2:-}"
	[[ -z "$session_id" || -z "$task_id" ]] && return 0

	local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
	[[ ! -f "$tracker_file" ]] && return 0

	local temp_file
	temp_file=$(mktemp)
	if jq --arg id "$task_id" 'del(.tasks[$id])' "$tracker_file" >"$temp_file" 2>/dev/null; then
		mv "$temp_file" "$tracker_file"
	else
		rm -f "$temp_file"
	fi
}

# Build a canonical task.* event from hook stdin (empty when unmapped).
# Usage: record=$(task_tracker_build_record "$INPUT")
task_tracker_build_record() {
	local input_json="${1:-}"
	onlooker_event_from_hook "$input_json"
}

# Append a canonical task event to session history (reuses tool-history flock).
# Usage: task_tracker_append "$SESSION_ID" "$event_json"
task_tracker_append() {
	tool_history_append "$1" "$2"
}

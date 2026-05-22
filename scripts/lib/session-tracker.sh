#!/usr/bin/env bash
# Session lifecycle helpers — session.start / session.end canonical events.
#
# Source after validate-path.sh, onlooker-schema.sh, and tool-history.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/session-tracker.sh"

# Milliseconds since epoch (macOS-compatible).
session_tracker_now_ms() {
	if [[ "$(uname)" == "Darwin" ]]; then
		python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || date +%s000
	else
		date +%s%3N 2>/dev/null || date +%s000
	fi
}

# Optional git_branch and git_commit for a working directory (empty when not a repo).
session_tracker_git_context() {
	local cwd="${1:-}"
	local branch="" commit=""
	[[ -z "$cwd" ]] && return 0

	if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		branch=$(git -C "$cwd" branch --show-current 2>/dev/null) || branch=""
		commit=$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null) || commit=""
	fi

	printf '%s\n%s' "$branch" "$commit"
}

# Map Claude Code SessionEnd reason to schema end_reason.
session_tracker_map_end_reason() {
	local reason="${1:-other}"
	case "$reason" in
	clear | logout | prompt_input_exit) echo "user_exit" ;;
	timeout) echo "timeout" ;;
	error) echo "error" ;;
	task_complete) echo "task_complete" ;;
	*) echo "unknown" ;;
	esac
}

# Merge session start metadata into the per-session tracker file.
# Usage: session_tracker_record_start "$SESSION_ID" "$INPUT_JSON"
session_tracker_record_start() {
	local session_id="${1:-}"
	local input_json="${2:-}"
	[[ -z "$session_id" || "$session_id" == "null" || -z "$input_json" ]] && return 0

	turn_state_ensure_session "$session_id" || return 1

	local tracker_file="$ONLOOKER_SESSION_TRACKERS_DIR/$session_id"
	local now_ms source model cwd transcript_path agent_type
	now_ms=$(session_tracker_now_ms)
	source=$(echo "$input_json" | jq -r '.source // ""' 2>/dev/null) || source=""
	model=$(echo "$input_json" | jq -r '.model // ""' 2>/dev/null) || model=""
	cwd=$(echo "$input_json" | jq -r '.cwd // ""' 2>/dev/null) || cwd=""
	transcript_path=$(echo "$input_json" | jq -r '.transcript_path // ""' 2>/dev/null) || transcript_path=""
	agent_type=$(echo "$input_json" | jq -r '.agent_type // ""' 2>/dev/null) || agent_type=""

	local temp_file
	temp_file=$(mktemp)
	if ! jq \
		--argjson start_ms "$now_ms" \
		--arg source "$source" \
		--arg model "$model" \
		--arg cwd "$cwd" \
		--arg transcript "$transcript_path" \
		--arg agent_type "$agent_type" \
		'.start_time_ms = $start_ms
		| .start_source = (if $source != "" then $source else .start_source end)
		| .model = (if $model != "" then $model else .model end)
		| .cwd = (if $cwd != "" then $cwd else .cwd end)
		| .transcript_path = (if $transcript != "" then $transcript else .transcript_path end)
		| .agent_type = (if $agent_type != "" then $agent_type else .agent_type end)' \
		"$tracker_file" >"$temp_file" 2>/dev/null; then
		rm -f "$temp_file"
		return 1
	fi
	mv "$temp_file" "$tracker_file"
}

# Build session.start payload JSON from hook input and tracker state.
# Usage: payload=$(session_tracker_build_start_payload "$INPUT_JSON")
session_tracker_build_start_payload() {
	local input_json="${1:-}"
	local cwd
	cwd=$(echo "$input_json" | jq -r '.cwd // ""' 2>/dev/null) || cwd=""
	[[ -z "$cwd" ]] && cwd="$(pwd)"

	local git_lines branch commit
	git_lines=$(session_tracker_git_context "$cwd")
	branch=$(echo "$git_lines" | sed -n '1p')
	commit=$(echo "$git_lines" | sed -n '2p')

	jq -n \
		--arg wd "$cwd" \
		--arg branch "$branch" \
		--arg commit "$commit" \
		'{
			working_directory: $wd
		}
		+ (if $branch != "" then {git_branch: $branch} else {} end)
		+ (if $commit != "" then {git_commit: $commit} else {} end)'
}

# Build session.end payload JSON from hook input and tracker file.
# Usage: payload=$(session_tracker_build_end_payload "$SESSION_ID" "$INPUT_JSON")
session_tracker_build_end_payload() {
	local session_id="${1:-}"
	local input_json="${2:-}"
	[[ -z "$session_id" || "$session_id" == "null" ]] && return 1

	local tracker_file="$ONLOOKER_SESSION_TRACKERS_DIR/$session_id"
	local now_ms start_ms turn_count reason end_reason duration_ms
	now_ms=$(session_tracker_now_ms)
	reason=$(echo "$input_json" | jq -r '.reason // "other"' 2>/dev/null) || reason="other"
	end_reason=$(session_tracker_map_end_reason "$reason")

	if [[ -f "$tracker_file" ]]; then
		start_ms=$(jq -r '.start_time_ms // 0' "$tracker_file" 2>/dev/null) || start_ms=0
		turn_count=$(jq -r '.turn_number // 1' "$tracker_file" 2>/dev/null) || turn_count=1
	else
		start_ms=0
		turn_count=1
	fi

	if [[ "$start_ms" =~ ^[0-9]+$ ]] && (( start_ms > 0 )); then
		duration_ms=$((now_ms - start_ms))
	else
		duration_ms=0
	fi
	(( duration_ms < 0 )) && duration_ms=0

	jq -n \
		--argjson duration_ms "$duration_ms" \
		--argjson turn_count "$turn_count" \
		--arg end_reason "$end_reason" \
		'{
			duration_ms: $duration_ms,
			turn_count: $turn_count,
			end_reason: $end_reason
		}'
}

# Emit a validated canonical session event and append to logs.
# Usage: session_tracker_emit "$SESSION_ID" "session.start" "$payload_json"
session_tracker_emit() {
	local session_id="${1:-}"
	local event_type="${2:-}"
	local payload_json="${3:-}"
	[[ -z "$session_id" || -z "$event_type" || -z "$payload_json" ]] && return 0

	local params event
	params=$(jq -n \
		--arg plugin "${ONLOOKER_PLUGIN_NAME:-onlooker}" \
		--arg sid "$session_id" \
		--arg type "$event_type" \
		--argjson payload "$payload_json" \
		'{plugin: $plugin, session_id: $sid, event_type: $type, payload: $payload}')

	event=$(printf '%s' "$params" | ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="$ONLOOKER_PLUGIN_NAME" \
		node "${_ONLOOKER_EVENT_JS:-${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/onlooker-event.mjs}" emit 2>/dev/null) || return 1

	tool_history_append "$session_id" "$event" || return 1
	onlooker_append_event "$event" || return 1
}

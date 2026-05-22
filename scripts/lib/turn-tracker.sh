#!/usr/bin/env bash
# Turn tracking helpers for UserPromptSubmit hooks.
#
# Source after validate-path.sh, onlooker-schema.sh, tool-history.sh, session-tracker.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/turn-tracker.sh"

# Truncate prompt text for session.prompt input_summary.
# Usage: summary=$(turn_tracker_summarize_prompt "$PROMPT")
turn_tracker_summarize_prompt() {
	local prompt="${1:-}"
	[[ -z "$prompt" ]] && return 0

	local summary
	summary=$(printf '%s' "$prompt" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/^ //;s/ $//')
	if ((${#summary} > 200)); then
		summary="${summary:0:200}…"
	fi
	printf '%s' "$summary"
}

# Advance turn state when the user submits a prompt (first prompt stays at turn 1).
# Usage: turn_tracker_on_user_prompt "$SESSION_ID"
turn_tracker_on_user_prompt() {
	local session_id="${1:-}"
	[[ -z "$session_id" || "$session_id" == "null" ]] && return 0

	turn_state_ensure_session "$session_id" || return 1

	local tracker_file="$ONLOOKER_SESSION_TRACKERS_DIR/$session_id"
	local seen
	seen=$(jq -r '.user_prompts_seen // false' "$tracker_file" 2>/dev/null) || seen="false"

	if [[ "$seen" == "true" ]]; then
		turn_state_next_turn "$session_id" || return 1
	else
		local temp_file
		temp_file=$(mktemp)
		if ! jq '.user_prompts_seen = true | .turn_tool_seq = 0' \
			"$tracker_file" >"$temp_file" 2>/dev/null; then
			rm -f "$temp_file"
			return 1
		fi
		mv "$temp_file" "$tracker_file"
	fi
}

# Build session.prompt payload for the current turn.
# Usage: payload=$(turn_tracker_build_prompt_payload "$SESSION_ID" "$PROMPT")
turn_tracker_build_prompt_payload() {
	local session_id="${1:-}"
	local prompt="${2:-}"
	[[ -z "$session_id" || "$session_id" == "null" ]] && return 1

	local turn_number summary
	if [[ -f "$ONLOOKER_SESSION_TRACKERS_DIR/$session_id" ]]; then
		turn_number=$(jq -r '.turn_number // 1' "$ONLOOKER_SESSION_TRACKERS_DIR/$session_id" 2>/dev/null) || turn_number=1
	else
		turn_number=1
	fi

	summary=$(turn_tracker_summarize_prompt "$prompt")

	jq -n \
		--argjson turn_number "$turn_number" \
		--arg summary "$summary" \
		'{turn_number: $turn_number}
		+ (if $summary != "" then {input_summary: $summary} else {} end)'
}

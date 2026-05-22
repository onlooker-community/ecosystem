#!/usr/bin/env bash
# Context compaction helpers — pre/post compact state and session.compact events.
#
# Source after validate-path.sh, onlooker-schema.sh, tool-history.sh, session-tracker.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/compact-tracker.sh"

# Rough token estimate from byte length (chars / 4).
# Usage: tokens=$(compact_tracker_estimate_tokens "$text_or_path" [is_file])
compact_tracker_estimate_tokens() {
	local value="${1:-}"
	local is_file="${2:-false}"
	local bytes=0

	if [[ -z "$value" ]]; then
		echo 0
		return 0
	fi

	if [[ "$is_file" == "true" && -f "$value" ]]; then
		bytes=$(wc -c <"$value" 2>/dev/null | tr -d ' ') || bytes=0
	elif [[ "$is_file" == "true" ]]; then
		echo 0
		return 0
	else
		bytes=${#value}
	fi

	[[ ! "$bytes" =~ ^[0-9]+$ ]] && bytes=0
	echo $((bytes / 4))
}

# Per-session compact state file path.
compact_tracker_state_file() {
	local session_id="${1:-}"
	printf '%s/%s' "$ONLOOKER_COMPACT_TRACKERS_DIR" "$session_id"
}

# Record pre-compact metadata before compaction runs.
# Usage: compact_tracker_record_pre "$SESSION_ID" "$INPUT_JSON"
compact_tracker_record_pre() {
	local session_id="${1:-}"
	local input_json="${2:-}"
	[[ -z "$session_id" || "$session_id" == "null" || -z "$input_json" ]] && return 0

	ensure_dir_exists "$ONLOOKER_COMPACT_TRACKERS_DIR" || return 1
	turn_state_ensure_session "$session_id" || return 1

	local trigger custom_instructions transcript_path tokens_before turn_number now_ms state_file
	trigger=$(echo "$input_json" | jq -r '.trigger // "auto"' 2>/dev/null) || trigger="auto"
	custom_instructions=$(echo "$input_json" | jq -r '.custom_instructions // ""' 2>/dev/null) || custom_instructions=""
	transcript_path=$(echo "$input_json" | jq -r '.transcript_path // ""' 2>/dev/null) || transcript_path=""
	now_ms=$(session_tracker_now_ms)
	state_file=$(compact_tracker_state_file "$session_id")

	tokens_before=0
	if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
		tokens_before=$(compact_tracker_estimate_tokens "$transcript_path" true)
	fi

	if [[ -f "$ONLOOKER_SESSION_TRACKERS_DIR/$session_id" ]]; then
		turn_number=$(jq -r '.turn_number // 1' "$ONLOOKER_SESSION_TRACKERS_DIR/$session_id" 2>/dev/null) || turn_number=1
	else
		turn_number=1
	fi

	local prior_count=0
	if [[ -f "$state_file" ]]; then
		prior_count=$(jq -r '.compact_count // 0' "$state_file" 2>/dev/null) || prior_count=0
	fi
	[[ ! "$prior_count" =~ ^[0-9]+$ ]] && prior_count=0

	jq -n \
		--argjson started_ms "$now_ms" \
		--arg trigger "$trigger" \
		--arg instructions "$custom_instructions" \
		--argjson tokens_before "$tokens_before" \
		--argjson turn_number "$turn_number" \
		--argjson compact_count $((prior_count + 1)) \
		'{
			pending: true,
			started_ms: $started_ms,
			trigger: $trigger,
			custom_instructions: (if $instructions != "" then $instructions else null end),
			tokens_before: $tokens_before,
			turn_number: $turn_number,
			compact_count: $compact_count
		}' >"$state_file"
}

# Append compact summary to session summaries dir (JSONL).
# Usage: compact_tracker_append_summary "$SESSION_ID" "$INPUT_JSON"
compact_tracker_append_summary() {
	local session_id="${1:-}"
	local input_json="${2:-}"
	[[ -z "$session_id" || "$session_id" == "null" ]] && return 0

	local summary trigger
	summary=$(echo "$input_json" | jq -r '.compact_summary // ""' 2>/dev/null) || summary=""
	[[ -z "$summary" ]] && return 0

	trigger=$(echo "$input_json" | jq -r '.trigger // "auto"' 2>/dev/null) || trigger="auto"

	ensure_dir_exists "$ONLOOKER_SESSION_SUMMARIES_DIR" || return 1
	local summary_file="${ONLOOKER_SESSION_SUMMARIES_DIR}/${session_id}.jsonl"
	local record
	record=$(jq -n \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S)" \
		--arg trigger "$trigger" \
		--arg summary "$summary" \
		'{recorded_at: $ts, trigger: $trigger, compact_summary: $summary}')

	printf '%s\n' "$record" >>"$summary_file" 2>/dev/null
}

# Build session.compact payload from pre state and post-compact summary.
# Usage: payload=$(compact_tracker_build_compact_payload "$SESSION_ID" "$INPUT_JSON")
compact_tracker_build_compact_payload() {
	local session_id="${1:-}"
	local input_json="${2:-}"
	[[ -z "$session_id" || "$session_id" == "null" ]] && return 1

	local summary tokens_before tokens_after ratio state_file
	summary=$(echo "$input_json" | jq -r '.compact_summary // ""' 2>/dev/null) || summary=""
	tokens_after=$(compact_tracker_estimate_tokens "$summary" false)
	(( tokens_after < 1 )) && tokens_after=1

	state_file=$(compact_tracker_state_file "$session_id")
	if [[ -f "$state_file" ]]; then
		tokens_before=$(jq -r '.tokens_before // 0' "$state_file" 2>/dev/null) || tokens_before=0
	fi
	[[ ! "$tokens_before" =~ ^[0-9]+$ ]] && tokens_before=0

	if (( tokens_before < tokens_after )); then
		tokens_before=$((tokens_after * 2))
	fi
	(( tokens_before < 1 )) && tokens_before=1

	ratio=$(awk "BEGIN {printf \"%.4f\", $tokens_after / $tokens_before}")

	jq -n \
		--argjson tokens_before "$tokens_before" \
		--argjson tokens_after "$tokens_after" \
		--argjson ratio "$ratio" \
		'{
			tokens_before: $tokens_before,
			tokens_after: $tokens_after,
			compression_ratio: $ratio
		}'
}

# Finalize compact state after PostCompact.
# Usage: compact_tracker_record_post "$SESSION_ID" "$INPUT_JSON"
compact_tracker_record_post() {
	local session_id="${1:-}"
	local input_json="${2:-}"
	[[ -z "$session_id" || "$session_id" == "null" ]] && return 0

	local state_file now_ms summary_len trigger
	state_file=$(compact_tracker_state_file "$session_id")
	now_ms=$(session_tracker_now_ms)
	summary_len=$(echo "$input_json" | jq -r '.compact_summary // ""' 2>/dev/null | wc -c | tr -d ' ') || summary_len=0
	trigger=$(echo "$input_json" | jq -r '.trigger // "auto"' 2>/dev/null) || trigger="auto"

	if [[ ! -f "$state_file" ]]; then
		compact_tracker_record_pre "$session_id" "$input_json"
		state_file=$(compact_tracker_state_file "$session_id")
	fi

	local temp_file
	temp_file=$(mktemp)
	if ! jq \
		--argjson completed_ms "$now_ms" \
		--argjson summary_chars "$summary_len" \
		--arg trigger "$trigger" \
		'.pending = false
		| .completed_ms = $completed_ms
		| .last_trigger = $trigger
		| .last_summary_chars = $summary_chars' \
		"$state_file" >"$temp_file" 2>/dev/null; then
		rm -f "$temp_file"
		return 1
	fi
	mv "$temp_file" "$state_file"

	# Reset per-turn tool sequence after compaction (new context window).
	local tracker_file="$ONLOOKER_SESSION_TRACKERS_DIR/$session_id"
	if [[ -f "$tracker_file" ]]; then
		temp_file=$(mktemp)
		if jq --argjson now_ms "$now_ms" \
			'.turn_tool_seq = 0 | .last_compact_ms = $now_ms' \
			"$tracker_file" >"$temp_file" 2>/dev/null; then
			mv "$temp_file" "$tracker_file"
		else
			rm -f "$temp_file"
		fi
	fi
}

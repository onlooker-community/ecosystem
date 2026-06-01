#!/usr/bin/env bash
# Prior assistant turn reader for Compass.
#
# Resolves the most recent assistant turn from the session transcript so
# the evaluator can operate on the pair {prior_assistant_turn, context}
# rather than context alone — avoiding false positives on question-answer
# turns (see ADR-001).
#
# Resolution order:
#   1. CLAUDE_TRANSCRIPT_PATH env var → parse as JSONL, find most recent
#      entry with role:"assistant"
#   2. Onlooker JSONL event log (~/.onlooker/logs/onlooker-events.jsonl)
#      filtered by session_id and event_type:"session.prompt", most recent
#      assistant-role entry
#   3. Empty string — degrades gracefully; evaluator runs on context alone
#
# Exposes:
#   compass_read_prior_turn <session_id> <max_chars> <max_age_seconds>
#     Echoes the prior assistant turn text (possibly empty).

_compass_transcript_from_path() {
	local transcript_path="$1"
	local session_id="$2"
	local max_age_seconds="$3"

	[[ -f "$transcript_path" ]] || return 1

	local now
	now=$(date +%s 2>/dev/null) || now=0

	# Parse JSONL: find most recent entry with role=assistant within max_age_seconds.
	# Each line is a JSON object. We want the last one matching our criteria.
	local prior_turn=""
	local line
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local role ts content
		role=$(printf '%s' "$line" | jq -r '.role // empty' 2>/dev/null) || continue
		[[ "$role" == "assistant" ]] || continue

		# Age check — skip entries older than max_age_seconds.
		if [[ "$max_age_seconds" -gt 0 ]]; then
			ts=$(printf '%s' "$line" | jq -r '.timestamp // empty' 2>/dev/null) || ts=""
			if [[ -n "$ts" ]]; then
				local entry_time
				entry_time=$(date -d "$ts" +%s 2>/dev/null) \
					|| entry_time=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null) \
					|| entry_time=0
				local age=$(( now - entry_time ))
				[[ "$age" -gt "$max_age_seconds" ]] && continue
			fi
		fi

		content=$(printf '%s' "$line" | jq -r '.content // .text // empty' 2>/dev/null) || continue
		[[ -n "$content" ]] && prior_turn="$content"
	done < "$transcript_path"

	[[ -n "$prior_turn" ]] || return 1
	printf '%s' "$prior_turn"
}

_compass_transcript_from_event_log() {
	local session_id="$1"
	local max_age_seconds="$2"
	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"

	[[ -f "$log_path" ]] || return 1
	[[ -n "$session_id" && "$session_id" != "unknown" ]] || return 1

	local now
	now=$(date +%s 2>/dev/null) || now=0

	local prior_turn=""
	local line
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		local sid etype role
		sid=$(printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null) || continue
		[[ "$sid" == "$session_id" ]] || continue

		etype=$(printf '%s' "$line" | jq -r '.event_type // empty' 2>/dev/null) || continue
		[[ "$etype" == "session.prompt" ]] || continue

		role=$(printf '%s' "$line" | jq -r '.payload.role // empty' 2>/dev/null) || continue
		[[ "$role" == "assistant" ]] || continue

		if [[ "$max_age_seconds" -gt 0 ]]; then
			local ts entry_time
			ts=$(printf '%s' "$line" | jq -r '.timestamp // empty' 2>/dev/null) || ts=""
			if [[ -n "$ts" ]]; then
				entry_time=$(date -d "$ts" +%s 2>/dev/null) \
					|| entry_time=$(date -jf '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null) \
					|| entry_time=0
				local age=$(( now - entry_time ))
				[[ "$age" -gt "$max_age_seconds" ]] && continue
			fi
		fi

		local content
		content=$(printf '%s' "$line" | jq -r '.payload.content // .payload.text // empty' 2>/dev/null) || continue
		[[ -n "$content" ]] && prior_turn="$content"
	done < "$log_path"

	[[ -n "$prior_turn" ]] || return 1
	printf '%s' "$prior_turn"
}

# Read the prior assistant turn.
#   $1 — session_id
#   $2 — max_chars (from config: transcript.prior_turn_chars_max)
#   $3 — max_age_seconds (from config: transcript.transcript_max_age_seconds)
# Echoes the sanitized, truncated prior assistant turn, or empty string.
compass_read_prior_turn() {
	local session_id="${1:-unknown}"
	local max_chars="${2:-800}"
	local max_age_seconds="${3:-300}"

	local raw=""

	# Source 1: CLAUDE_TRANSCRIPT_PATH
	if [[ -n "${CLAUDE_TRANSCRIPT_PATH:-}" ]]; then
		raw=$(_compass_transcript_from_path "$CLAUDE_TRANSCRIPT_PATH" "$session_id" "$max_age_seconds") || raw=""
	fi

	# Source 2: Onlooker event log
	if [[ -z "$raw" ]]; then
		raw=$(_compass_transcript_from_event_log "$session_id" "$max_age_seconds") || raw=""
	fi

	[[ -z "$raw" ]] && return 0

	# Sanitize and truncate — compass-sanitizer.sh must be sourced by the caller.
	compass_sanitize "$raw" "$max_chars"
}

#!/usr/bin/env bash
# Prior assistant turn reader for Compass.
#
# Resolves the most recent assistant turn from the session transcript JSONL
# so the evaluator can operate on the pair {prior_assistant_turn, context}
# rather than context alone. Avoids false positives on question-answer
# turns. See ADR-001 (plugins/compass/docs/adr/001-evaluate-prompts-in-context.md).
#
# Source: the `transcript_path` field from the hook JSON payload. This is
# the same field tribunal-stop-gate.sh reads (`jq -r '.transcript_path // ""'`).
# When `transcript_path` is absent or unreadable, this function returns the
# empty string and the evaluator runs on the current context alone.
#
# Exposes:
#   compass_read_prior_turn <transcript_path> <max_chars>
#     Echoes the sanitized, truncated prior assistant turn, or empty string.

# Extract the text portion of a transcript line. The Claude Code session
# transcript stores assistant messages as `{"type":"assistant","message":{...}}`
# where `message.content` may be a string or an array of content blocks.
_compass_transcript_extract_text() {
	local line="$1"
	# Prefer message.content[*].text for the array-of-blocks shape; fall back
	# to message.content when it is already a string. Final fallback: any
	# top-level .content or .text field (covers legacy/alternate writers).
	printf '%s' "$line" | jq -r '
		if (.message? // null) != null then
			if (.message.content | type) == "array" then
				[.message.content[]? | select(type == "object") | (.text // "")]
				| map(select(. != "")) | join("\n")
			elif (.message.content | type) == "string" then
				.message.content
			else "" end
		else
			(.content // .text // "")
		end
	' 2>/dev/null
}

# Return the role for a transcript line, falling back to .message.role.
_compass_transcript_role() {
	local line="$1"
	printf '%s' "$line" \
		| jq -r '(.role // .message.role // .type // empty)' 2>/dev/null
}

# Walk a JSONL transcript file backwards to find the most recent assistant
# turn with non-empty text. Avoids loading the entire file into memory by
# streaming with `tac` when available; falls back to `tail -r` on BSD.
# Walk a JSONL transcript backwards for the most recent line of $role that
# carries non-empty text, echoing either that text or the raw line.
#   $1 — transcript path
#   $2 — role to match ("assistant" | "user"); default assistant
#   $3 — what to echo: "text" (default) or "line"
#
# The non-empty-text requirement is what makes the user role mean "the last
# thing the human said". Tool results are user-role lines too, but they carry
# tool_result blocks rather than text, so _compass_transcript_extract_text
# yields nothing for them and they are passed over.
_compass_transcript_find_last() {
	local path="$1"
	local want_role="${2:-assistant}"
	local emit="${3:-text}"
	[[ -f "$path" ]] || return 1

	local reverser=""
	if command -v tac >/dev/null 2>&1; then
		reverser="tac"
	elif command -v tail >/dev/null 2>&1 && tail -r </dev/null >/dev/null 2>&1; then
		reverser="tail -r"
	fi

	local line role content
	if [[ -n "$reverser" ]]; then
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			role=$(_compass_transcript_role "$line") || continue
			[[ "$role" == "$want_role" ]] || continue
			content=$(_compass_transcript_extract_text "$line") || continue
			[[ -n "$content" ]] || continue
			if [[ "$emit" == "line" ]]; then
				printf '%s' "$line"
			else
				printf '%s' "$content"
			fi
			return 0
		done < <(eval "$reverser" "\"$path\"" 2>/dev/null)
	else
		# Final fallback: forward scan, keep the last match.
		local found="" found_line=""
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			role=$(_compass_transcript_role "$line") || continue
			[[ "$role" == "$want_role" ]] || continue
			content=$(_compass_transcript_extract_text "$line") || continue
			[[ -n "$content" ]] && { found="$content"; found_line="$line"; }
		done < "$path"
		if [[ -n "$found" ]]; then
			if [[ "$emit" == "line" ]]; then
				printf '%s' "$found_line"
			else
				printf '%s' "$found"
			fi
			return 0
		fi
	fi

	return 1
}

# Preserved signature: the prior assistant turn's text (ADR-001's evaluator
# input). Delegates so there is one backwards scan to maintain, not two.
_compass_transcript_read_from_file() {
	_compass_transcript_find_last "$1" "assistant" "text"
}

# Echo the raw JSONL line of the most recent human user message, or nothing.
# The caller wants two things from it — the text, for the override phrase, and
# the uuid, as a turn identifier — so this returns the line rather than making
# the caller scan twice.
compass_read_user_turn_line() {
	local transcript_path="${1:-}"
	[[ -z "$transcript_path" ]] && return 0
	_compass_transcript_find_last "$transcript_path" "user" "line" || return 0
}

# Read the prior assistant turn.
#   $1 — transcript_path (from hook JSON payload; may be empty)
#   $2 — max_chars (from config: transcript.prior_turn_chars_max)
# Echoes the sanitized, truncated prior assistant turn, or the empty string.
compass_read_prior_turn() {
	local transcript_path="${1:-}"
	local max_chars="${2:-800}"

	[[ -z "$transcript_path" ]] && return 0

	local raw=""
	raw=$(_compass_transcript_read_from_file "$transcript_path") || raw=""
	[[ -z "$raw" ]] && return 0

	# compass-sanitizer.sh is sourced by the caller (hook script).
	compass_sanitize "$raw" "$max_chars"
}

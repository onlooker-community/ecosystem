#!/usr/bin/env bash
# Intent extraction for Scribe.
#
# Reads a session transcript and runs a Haiku pass to extract structured
# intent documentation: the problem being solved, decisions made and why,
# tradeoffs, constraints, and what was explicitly left out.
#
# This is documentation from intent, not from code. The output answers
# WHY, not WHAT — git logs and code comments cover what.
#
# Exposes:
#   scribe_count_turns <transcript_path>
#     Echoes the number of user turns found in the transcript (integer).
#
#   scribe_extract_intent <transcript_path> <model> <timeout> <max_tokens> <temperature>
#     Echoes a JSON object on success, empty string on failure.
#     JSON shape:
#       {
#         "problem":      string,
#         "decisions":    [{decision, reason, alternatives:[]}],
#         "tradeoffs":    [string],
#         "constraints":  [string],
#         "out_of_scope": [string],
#         "summary":      string
#       }

_SCRIBE_EXTRACT_PROMPT='You are an intent documentation assistant. Analyze this agent session transcript and extract structured documentation about WHY changes were made — the problem context, decisions, tradeoffs, and constraints that shaped the work. This is documentation from intent, not from code.

Do NOT describe what was done. Focus exclusively on why decisions were made.

Return a JSON object with exactly these keys:
{
  "problem": "1-3 sentences: what problem or goal initiated this session",
  "decisions": [
    {
      "decision": "what was decided",
      "reason": "why this approach was chosen",
      "alternatives": ["alternative that was considered but rejected"]
    }
  ],
  "tradeoffs": ["tradeoff description — what was gained vs. given up"],
  "constraints": ["constraint that shaped decisions"],
  "out_of_scope": ["what was explicitly not done, and why"],
  "summary": "2-3 sentences: executive summary of the session intent and key decisions"
}

Rules:
- All fields are required; use empty arrays [] if no items found
- Keep each item to 1-2 sentences
- Return ONLY the JSON object — no prose, no markdown fences, no explanation

'

scribe_count_turns() {
	local transcript_path="${1:-}"
	[[ -f "$transcript_path" ]] || { printf '0'; return 0; }

	local count=0
	local line
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local role
		role=$(printf '%s' "$line" | jq -r '.role // empty' 2>/dev/null) || continue
		[[ "$role" == "user" ]] && count=$((count + 1))
	done < "$transcript_path"

	printf '%s' "$count"
}

scribe_extract_intent() {
	local transcript_path="${1:-}"
	local model="${2:-claude-haiku-4-5-20251001}"
	local timeout_s="${3:-60}"
	local max_tokens="${4:-2048}"
	local temperature="${5:-0.3}"
	local transcript_chars_max="${6:-40000}"

	[[ -f "$transcript_path" ]] || return 1

	local transcript_content
	transcript_content=$(jq -r '
		select(.role != null) |
		if .role == "user" then
			"[User]\n" + (
				if (.content | type) == "array" then
					[.content[] | select(.type == "text") | .text] | join("\n")
				else
					(.content // "")
				end
			)
		elif .role == "assistant" then
			"[Assistant]\n" + (
				if (.content | type) == "array" then
					[.content[] | select(.type == "text") | .text] | join("\n")
				else
					(.content // "")
				end
			)
		else empty end
	' "$transcript_path" 2>/dev/null | head -c "$transcript_chars_max") || transcript_content=""

	[[ -z "$transcript_content" ]] && return 1

	local prompt_file
	prompt_file=$(mktemp -t scribe-extract.XXXXXX 2>/dev/null) || prompt_file="/tmp/scribe-extract.$$"
	trap 'rm -f "$prompt_file"' RETURN

	{
		printf '%s' "$_SCRIBE_EXTRACT_PROMPT"
		printf '<session_transcript>\n'
		printf '%s\n' "$transcript_content"
		printf '</session_transcript>\n'
	} > "$prompt_file"

	if ! command -v claude >/dev/null 2>&1; then
		printf 'scribe_extract_intent: claude CLI not found\n' >&2
		return 1
	fi

	local claude_args=(-p --max-turns 1 --model "$model" --max-tokens "$max_tokens")

	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$timeout_s" claude "${claude_args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$timeout_s" claude "${claude_args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(claude "${claude_args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi

	[[ -z "$response" ]] && return 1

	# Strip markdown fences if present.
	local clean
	clean=$(printf '%s' "$response" \
		| sed -e 's/^```json[[:space:]]*//' -e 's/^```[[:space:]]*//' -e 's/[[:space:]]*```$//')

	# Validate all required keys from the extraction prompt.
	if ! printf '%s' "$clean" | jq -e \
		'.problem and (.decisions | type == "array") and (.tradeoffs | type == "array") and (.constraints | type == "array") and (.out_of_scope | type == "array") and .summary' \
		>/dev/null 2>&1; then
		printf 'scribe_extract_intent: response missing required keys\n' >&2
		return 1
	fi

	printf '%s' "$clean"
}

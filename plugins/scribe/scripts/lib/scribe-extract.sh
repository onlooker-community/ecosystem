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

	# One streaming jq pass, not one process per line. The loop this replaced
	# spawned a jq per line (two on user lines) and cost ~3.2ms/line, which is
	# where scribe-stop's 751ms-6.3s came from — ecosystem-449.43 read that as
	# the LLM path, and it never was. Measured 2.17s on a 674-line transcript.
	#
	# -R with `fromjson? // empty` keeps every tolerance the loop had: blank
	# lines and unparseable lines drop out silently rather than aborting the
	# count. Only user entries whose content is a string count, so tool results
	# (array content) stay excluded.
	local count
	count=$(jq -R -r '
		fromjson? // empty
		| select(.type == "user")
		| select((.message.content | type) == "string")
		| 1
	' "$transcript_path" 2>/dev/null | wc -l | tr -d '[:space:]') || count=0
	[[ -z "$count" ]] && count=0

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
		select(.type == "user" or .type == "assistant") |
		if .type == "user" then
			"[User]\n" + (
				if (.message.content | type) == "array" then
					[.message.content[] | select(.type == "text") | .text] | join("\n")
				else
					(.message.content // "")
				end
			)
		elif .type == "assistant" then
			"[Assistant]\n" + (
				if (.message.content | type) == "array" then
					[.message.content[] | select(.type == "text") | .text] | join("\n")
				else
					(.message.content // "")
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

	# No --max-tokens: the claude CLI has no such option and rejects it outright
	# ("error: unknown option '--max-tokens'", exit 1). Passing it meant every
	# extraction scribe ever attempted failed in ~0.14s, and because the CLI's
	# stderr went to /dev/null the reason was never recorded anywhere — scribe
	# wrote 13,201 capture files and produced not one distilled artifact. See
	# ecosystem-449.54. The CLI exposes no output-token cap, so $max_tokens is
	# accepted for signature stability and deliberately not forwarded.
	local claude_args=(-p --max-turns 1 --model "$model")

	# Keep the CLI's stderr. Discarding it is what made the flag bug survive:
	# a hard failure and a quiet no-op looked identical from the outside.
	local cli_err
	cli_err=$(mktemp -t scribe-extract-err.XXXXXX 2>/dev/null) || cli_err="/tmp/scribe-extract-err.$$"

	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$timeout_s" claude "${claude_args[@]}" < "$prompt_file" 2>"$cli_err") || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$timeout_s" claude "${claude_args[@]}" < "$prompt_file" 2>"$cli_err") || response=""
	else
		response=$(claude "${claude_args[@]}" < "$prompt_file" 2>"$cli_err") || response=""
	fi

	if [[ -z "$response" ]]; then
		printf 'scribe_extract_intent: claude CLI produced no output\n' >&2
		[[ -s "$cli_err" ]] && cat "$cli_err" >&2
		rm -f "$cli_err"
		return 1
	fi
	rm -f "$cli_err"

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

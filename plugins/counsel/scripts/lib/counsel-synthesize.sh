#!/usr/bin/env bash
# Synthesis pass for Counsel.
#
# Runs a single Haiku call over the event summary to produce a structured
# improvement brief. The brief is returned as a JSON object.
#
# Exposes:
#   counsel_synthesize <events_text> <model> <timeout_s> <max_tokens> <temperature>
#     Echoes a JSON object on success, empty string on failure.
#     JSON shape:
#       {
#         "summary":         string,
#         "patterns":        [string],
#         "recommendations": [{title, rationale, priority:"high"|"medium"|"low"}],
#         "wins":            [string],
#         "watch":           [string]
#       }

_COUNSEL_SYNTHESIS_PROMPT='You are an engineering coach analyzing an AI agent observability log. You have been given a structured dump of plugin events from the onlooker ecosystem over the past several weeks. Your job is to synthesize patterns, surface improvement opportunities, and highlight what is working well.

Focus on:
- Recurring failure modes or blocked gates (tribunal, sentinel, warden)
- Prompt regression trends (echo plugin)
- Budget or resource pressure patterns (governor plugin)
- Quality trends over time
- What the team is consistently doing well

Return a JSON object with exactly these keys:
{
  "summary": "2-3 sentence executive summary of the period",
  "patterns": ["observed pattern — what is happening and how often"],
  "recommendations": [
    {
      "title": "short action title",
      "rationale": "1-2 sentences explaining why this matters",
      "priority": "high"
    }
  ],
  "wins": ["thing that is working well — be specific"],
  "watch": ["trend to monitor — not urgent but worth watching"]
}

Rules:
- All fields are required; use empty arrays [] if no items found
- recommendations must have priority: "high", "medium", or "low"
- Keep each item to 1-2 sentences
- Return ONLY the JSON object — no prose, no markdown fences, no explanation
- If there is insufficient data to draw conclusions, say so in summary and return empty arrays

'

counsel_synthesize() {
	local events_text="${1:-}"
	local model="${2:-claude-haiku-4-5-20251001}"
	local timeout_s="${3:-90}"
	# shellcheck disable=SC2034  # accepted for call-site compatibility; the
	# claude CLI print mode exposes no max-tokens/temperature flags, so neither
	# is forwarded (see claude_args below).
	local max_tokens="${4:-4096}"
	# shellcheck disable=SC2034
	local temperature="${5:-0.4}"

	[[ -z "$events_text" ]] && return 1

	if ! command -v claude >/dev/null 2>&1; then
		printf 'counsel_synthesize: claude CLI not found\n' >&2
		return 1
	fi

	local prompt_file
	prompt_file=$(mktemp -t counsel-synth.XXXXXX 2>/dev/null) || prompt_file="/tmp/counsel-synth.$$"
	trap 'rm -f "$prompt_file"' RETURN

	{
		printf '%s' "$_COUNSEL_SYNTHESIS_PROMPT"
		printf '<event_log>\n'
		printf '%s\n' "$events_text"
		printf '</event_log>\n'
	} > "$prompt_file"

	# NOTE: `claude -p` does not accept --max-tokens (it errors with "unknown
	# option") and has no temperature flag, so we pass neither. Output length is
	# governed by the model/prompt; the synthesis prompt asks for terse JSON.
	local claude_args=(-p --max-turns 1 --model "$model")

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

	if ! printf '%s' "$clean" | jq -e \
		'.summary and (.patterns | type == "array") and (.recommendations | type == "array") and (.wins | type == "array") and (.watch | type == "array")' \
		>/dev/null 2>&1; then
		printf 'counsel_synthesize: response missing required keys\n' >&2
		return 1
	fi

	printf '%s' "$clean"
}

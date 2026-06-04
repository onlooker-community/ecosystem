#!/usr/bin/env bash
# Transcript reader for Assayer.
#
# The Stop hook payload carries `transcript_path` — a JSONL file already
# committed to disk before Stop fires (same field tribunal and compass read).
# Assayer needs two things from it:
#
#   1. The final assistant message — the text the agent left the user with,
#      where claims like "I ran the tests, they pass" live.
#   2. The session's Bash commands paired with their result status — the
#      factual record to check those claims against.
#
# Claude Code transcripts represent a Bash invocation as a `tool_use` block
# (name "Bash", with `.input.command`) on an assistant line, and its outcome
# as a `tool_result` block on a following user line carrying the same
# `tool_use_id` and an `is_error` flag. There is no per-call numeric exit code
# in the transcript, so `is_error` is the success/failure signal.

# Echo the final assistant message text (text blocks of the last assistant
# turn that contains any), truncated to max_chars. Empty if unavailable.
#   $1 — transcript_path
#   $2 — max_chars (default 6000)
assayer_final_assistant_message() {
	local transcript_path="${1:-}"
	local max_chars="${2:-6000}"

	[[ -f "$transcript_path" ]] || return 0

	local text
	text=$(jq -s -r '
		[ .[]
		  | select(.type == "assistant")
		  | select(any(.message.content[]?; .type == "text"))
		]
		| last
		| if . == null then ""
		  else [ .message.content[]? | select(.type == "text") | .text ] | join("\n")
		  end
	' "$transcript_path" 2>/dev/null) || text=""

	[[ -z "$text" ]] && return 0
	printf '%s' "${text:0:$max_chars}"
}

# Echo a JSON array of the session's Bash commands paired with result status:
#   [ { "command": "...", "is_error": true|false, "excerpt": "..." }, ... ]
# Ordered as they appear in the transcript. `is_error` is false when the
# matching tool_result is absent or its is_error flag is not true.
#   $1 — transcript_path
assayer_collect_commands() {
	local transcript_path="${1:-}"

	[[ -f "$transcript_path" ]] || {
		printf '[]'
		return 0
	}

	local out
	out=$(jq -s -c '
		(
			[ .[]
			  | select(.type == "assistant")
			  | .message.content[]?
			  | select(.type == "tool_use" and .name == "Bash")
			  | { id: .id, command: (.input.command // "") }
			]
		) as $calls
		|
		(
			[ .[]
			  | select(.type == "user")
			  | .message.content[]?
			  | select(.type == "tool_result")
			  | {
				  id: .tool_use_id,
				  is_error: (.is_error == true),
				  excerpt: (
					if (.content | type) == "string" then .content
					elif (.content | type) == "array" then
					  ([ .content[]? | select(.type == "text") | .text ] | join("\n"))
					else "" end
				  )
				}
			]
		) as $results
		|
		[ $calls[]
		  | . as $c
		  | {
			  command: $c.command,
			  is_error: (first($results[] | select(.id == $c.id) | .is_error) // false),
			  excerpt: ((first($results[] | select(.id == $c.id) | .excerpt) // "")[0:240])
			}
		]
	' "$transcript_path" 2>/dev/null) || out=""

	[[ -z "$out" || "$out" == "null" ]] && out="[]"
	printf '%s' "$out"
}

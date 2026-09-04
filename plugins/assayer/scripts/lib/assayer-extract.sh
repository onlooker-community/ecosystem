#!/usr/bin/env bash
# Claim extraction for Assayer.
#
# The language-understanding half of the plugin: an LLM reads the agent's
# final message and pulls out *testable success claims* — assertions that some
# command or check succeeded ("I ran the tests, they pass", "the build is
# green", "lint is clean"). Each claim is tagged with a type and a
# command_keyword that the deterministic verifier (assayer-verify.sh) uses to
# locate the command that would corroborate or contradict it.
#
# The LLM does not judge truth — it only identifies claims and what command
# would settle them. The factual cross-check is pure bash, so it stays
# deterministic and testable.

# Cheap pre-filter: does this message plausibly assert that something SUCCEEDED?
#
# Gates the extraction LLM call. Across the first 449 audits, 346 (77%) came
# back with zero claims — the model was paid to read a message that asserted
# nothing (ecosystem-449.24).
#
# Deliberately generous. A false positive costs one Haiku call; a false
# negative silently defeats the plugin, so anything resembling an assertion of
# success gets through. Substring matching, not word matching, so "passes",
# "passed" and "passing" all fall out of "pass". Matching is case-insensitive
# via nocasematch rather than `${var,,}`, which is bash 4+ and macOS ships 3.2.
#
# Returns 0 if the message may contain claims, 1 if it certainly does not.
#   $1 — final assistant message text
assayer_may_contain_claims() {
	local message="${1:-}"
	[[ -z "$message" ]] && return 1

	local _restore_nocasematch
	_restore_nocasematch=$(shopt -p nocasematch)
	shopt -s nocasematch

	local verdict=1
	if [[ "$message" =~ (pass|green|clean|succe|verif|confirm|correct|fixed|created|restor|recover|complet|compil|built|work|ready|no\ error|zero\ error|exit\ 0|exit\ code\ 0|✓|✅) ]]; then
		verdict=0
	fi

	eval "$_restore_nocasematch"
	return "$verdict"
}

# Write the extraction prompt for a final assistant message to stdout.
#   $1 — final assistant message text
#   $2 — max_claims
assayer_build_extraction_prompt() {
	local message="${1:-}"
	local max_claims="${2:-12}"

	printf '%s\n' 'You are auditing an AI coding agent'"'"'s final message to its user.'
	printf '%s\n' 'Extract every TESTABLE SUCCESS CLAIM: a statement asserting that a command,'
	printf '%s\n' 'test, build, lint, or type check was run and SUCCEEDED. Ignore plans, intentions,'
	printf '%s\n' 'hedged statements ("should pass"), and claims about code that no shell command'
	printf '%s\n' 'could confirm.'
	printf '\n'
	printf '%s\n' 'Return JSON only — no prose, no markdown fences. A JSON array, possibly empty:'
	printf '%s\n' '['
	printf '%s\n' '  {'
	printf '%s\n' '    "text": "the exact claim, quoted from the message",'
	printf '%s\n' '    "type": "tests_pass|build_succeeds|lint_clean|types_check|command_succeeds|generic",'
	printf '%s\n' '    "command_keyword": "a lowercase substring you expect in the verifying shell command, e.g. test, build, lint, tsc",'
	printf '%s\n' '    "confidence": 0.0..1.0'
	printf '%s\n' '  }'
	printf '%s\n' ']'
	printf '\n'
	printf '%s\n' "Extract at most ${max_claims} claims, highest-confidence first."
	printf '\n'
	printf '%s\n' '---AGENT FINAL MESSAGE---'
	printf '%s\n' "$message"
	printf '%s\n' '---END MESSAGE---'
}

# Parse a claude -p response into a clean JSON array of claims.
# Strips markdown fences, validates it is a JSON array, and drops malformed
# entries. Echoes a compact JSON array (or "[]").
#   $1 — raw response text
assayer_parse_claims() {
	local raw="${1:-}"
	[[ -z "$raw" ]] && {
		printf '[]'
		return 0
	}

	# Strip leading/trailing markdown fences if present.
	local clean
	clean=$(printf '%s' "$raw" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')

	# Validate as a JSON array; keep only well-formed claim objects with a
	# non-empty text and a recognized type.
	local parsed
	parsed=$(printf '%s' "$clean" | jq -c '
		if type == "array" then
			[ .[]
			  | select(type == "object")
			  | select((.text // "") != "")
			  | {
				  text: .text,
				  type: (
					if (.type // "") | test("^(tests_pass|build_succeeds|lint_clean|types_check|command_succeeds|generic)$")
					then .type else "generic" end
				  ),
				  command_keyword: ((.command_keyword // "") | ascii_downcase),
				  confidence: (
					if (.confidence | type) == "number" then .confidence else 0.6 end
				  )
				}
			]
		else
			[]
		end
	' 2>/dev/null) || parsed="[]"

	[[ -z "$parsed" || "$parsed" == "null" ]] && parsed="[]"
	printf '%s' "$parsed"
}

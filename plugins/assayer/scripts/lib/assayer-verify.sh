#!/usr/bin/env bash
# Claim verification for Assayer.
#
# The deterministic half: given a claim (with a type and command_keyword) and
# the session's Bash commands paired with their is_error status, locate the
# command that would settle the claim and classify it. No LLM, no randomness —
# the same inputs always produce the same verdict.
#
# Matching: a claim type implies keywords (tests_pass -> "test", build_succeeds
# -> "build", ...); the LLM-supplied command_keyword is added. The MOST RECENT
# command containing any keyword wins, because an agent may fix and re-run, and
# the last run reflects the final state the claim describes.
#
# Verdicts:
#   corroborated  — matching command succeeded (is_error false)
#   contradicted  — matching command failed (is_error true)
#   unverified    — no matching command (reason no_matching_command), or the
#                   claim implies no checkable command (reason ambiguous)

# Classify a single claim against the collected commands.
# Echoes a JSON object: { verdict, evidence_command?, is_error?, excerpt?, reason? }
#   $1 — claim JSON object
#   $2 — commands JSON array (from assayer_collect_commands)
assayer_classify_claim() {
	local claim="${1:-}"
	local commands="${2:-[]}"

	[[ -z "$claim" ]] && {
		printf '{"verdict":"unverified","reason":"ambiguous"}'
		return 0
	}
	[[ -z "$commands" || "$commands" == "null" ]] && commands="[]"

	local result
	result=$(jq -n \
		--argjson claim "$claim" \
		--argjson commands "$commands" '
		def keywords:
			($claim.type // "generic") as $t
			| ( if $t == "tests_pass" then ["test"]
				elif $t == "build_succeeds" then ["build"]
				elif $t == "lint_clean" then ["lint"]
				elif $t == "types_check" then ["tsc", "typecheck", "type-check", "types"]
				else [] end ) as $base
			| ($base + (if (($claim.command_keyword // "") | length) > 0 then [$claim.command_keyword] else [] end))
			| map(ascii_downcase) | map(select(. != "")) | unique;

		keywords as $kw
		| if ($kw | length) == 0 then
			{ verdict: "unverified", reason: "ambiguous" }
		  else
			[ $commands[]
			  | . as $c
			  | select(($c.command | ascii_downcase) as $cmd | any($kw[]; . as $k | $cmd | contains($k)))
			] as $matches
			| if ($matches | length) == 0 then
				{ verdict: "unverified", reason: "no_matching_command" }
			  else
				($matches | last) as $m
				| {
					verdict: (if $m.is_error then "contradicted" else "corroborated" end),
					evidence_command: $m.command,
					is_error: $m.is_error,
					excerpt: ($m.excerpt // "")
				  }
			  end
		  end
	' 2>/dev/null) || result=""

	[[ -z "$result" || "$result" == "null" ]] && result='{"verdict":"unverified","reason":"ambiguous"}'
	printf '%s' "$result"
}

# Derive the overall audit verdict from the three counts.
#   $1 — contradicted count
#   $2 — corroborated count
#   $3 — unverified count
assayer_audit_verdict() {
	local contradicted="${1:-0}"
	local corroborated="${2:-0}"
	local unverified="${3:-0}"

	if [[ "$contradicted" -gt 0 ]]; then
		printf 'contradictions_found'
	elif [[ "$corroborated" -gt 0 ]]; then
		printf 'clean'
	else
		# No contradictions and nothing corroborated — only unverified (or none).
		if [[ "$unverified" -gt 0 ]]; then
			printf 'clean'
		else
			printf 'nothing_to_verify'
		fi
	fi
}

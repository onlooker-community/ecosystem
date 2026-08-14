#!/usr/bin/env bash
# Score aggregation for Tribunal.
#
# Aggregates per-judge verdicts into a single jury-level score per the chosen
# aggregation_method. Also computes the dissent metric (max - min) so callers
# can decide whether to emit tribunal.dissent.recorded.
#
# Verdicts input is a JSON array of TribunalVerdictPayload objects (or a subset
# containing at least { judge_id, score }). Rubric is the active rubric (for
# weighted_mean only).
#
# Exposes:
#   tribunal_aggregate <method> <verdicts_json> [<rubric_json>]
#       echoes the aggregated score (0..1) as a JSON number
#   tribunal_disagreement <verdicts_json>
#       echoes max(score) - min(score), or 0 if 0/1 verdicts
#
# weighted_mean uses *rubric criterion weights*: average the judges' scores on
# each criterion, weight each criterion's mean, and normalize by the weights
# actually used. A criterion no judge scored contributes nothing and its weight
# is excluded from the denominator — absence is not a zero. When no criterion
# has any score (every verdict emitted before judges shipped criterion_scores),
# weighted_mean degrades to mean rather than collapsing to 0.

tribunal_aggregate() {
	local method="${1:-mean}"
	local verdicts="${2:-[]}"
	local rubric="${3:-}"
	[ -z "$rubric" ] && rubric='{}'

	local count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" -eq 0 ]] && { printf '0'; return 0; }

	case "$method" in
		mean)
			printf '%s' "$verdicts" | jq -r '[.[].score] | add / length'
			;;
		weighted_mean)
			local weighted
			weighted=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
				. as $v
				| [ ($rubric.criteria // [])[]
				    | select((.name | type) == "string" and (.weight | type) == "number")
				    | . as $c
				    | ([ $v[]
				         | select((.criterion_scores | type) == "object")
				         | select(.criterion_scores | has($c.name))
				         | .criterion_scores[$c.name]
				         | select(type == "number") ]) as $scores
				    | select(($scores | length) > 0)
				    | { w: $c.weight, m: (($scores | add) / ($scores | length)) } ]
				| (map(.w) | add) as $den
				| if length == 0 or $den == null or $den <= 0 then empty
				  else (map(.w * .m) | add) / $den
				  end
			' 2>/dev/null)
			if [ -n "$weighted" ]; then
				printf '%s' "$weighted"
			else
				# No criterion carried a usable score — degrade to mean.
				printf '%s' "$verdicts" | jq -r '[.[].score] | add / length'
			fi
			;;
		median)
			printf '%s' "$verdicts" | jq -r '
				[.[].score] | sort as $s
				| ($s | length) as $n
				| if ($n % 2) == 1 then $s[($n - 1) / 2]
				  else (($s[$n / 2 - 1] + $s[$n / 2]) / 2)
				  end
			'
			;;
		min)
			printf '%s' "$verdicts" | jq -r '[.[].score] | min'
			;;
		*)
			printf 'tribunal-aggregate: unknown method %s, falling back to mean\n' \
				"$method" >&2
			printf '%s' "$verdicts" | jq -r '[.[].score] | add / length'
			;;
	esac
}

tribunal_disagreement() {
	local verdicts="${1:-[]}"
	local count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" -lt 2 ]] && { printf '0'; return 0; }
	printf '%s' "$verdicts" | jq -r '[.[].score] | (max - min)'
}

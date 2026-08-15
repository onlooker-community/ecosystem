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
#
# Normalizing by the weights actually scored is only honest once the panel has
# covered enough of the rubric. The judge agents are told to omit any criterion
# they cannot assess, so a panel that scores one cheap criterion and skips the
# rest would otherwise produce an aggregate computed entirely from that one and
# renormalized to look complete — and .score, the judge's own overall verdict,
# is never read here to contradict it. Two guards, and weighted_mean degrades to
# the plain mean of .score — the panel's own summary judgment — on either:
#
#   1. Any criterion carrying a min_pass went unscored. A weight fraction is the
#      wrong proxy for what a floor protects, because a floor protects one named
#      criterion. In the shipped default rubric correctness (0.4) plus
#      completeness (0.3) clears any coverage bar at or below 0.7 while skipping
#      safety, the highest floor there is — which reproduced the exact inversion
#      guard 2 was added to stop, one criterion further along.
#   2. The scored weight covers less than min_criterion_coverage of the rubric's
#      total declared weight. Still load-bearing for rubrics that mix floored and
#      unfloored criteria, where guard 1 has nothing to say.
#
# A criterion with no min_pass is exempt from guard 1 by design: absence is not a
# zero, and renormalizing over it stays correct. Only floors force the degrade,
# or every partial panel would collapse weighted_mean into mean.
#
# Degrading is deliberately not refusing — a blocked tribunal task retries. That
# is the asymmetry with librarian, which refuses (UNJUDGED) because a lesson
# published without its disclosure floor ever running is not recoverable.

tribunal_aggregate() {
	local method="${1:-mean}"
	local verdicts="${2:-[]}"
	local rubric="${3:-}"
	[ -z "$rubric" ] && rubric='{}'

	# This lib is sourced standalone in tests and does not pull in
	# tribunal-config.sh; fall back rather than adding a source line.
	local min_coverage
	if ! type tribunal_config_get >/dev/null 2>&1; then
		min_coverage="0.6"
	else
		min_coverage=$(tribunal_config_get '.tribunal.rubric.min_criterion_coverage' 2>/dev/null)
	fi
	case "$min_coverage" in
		''|null) min_coverage="0.6" ;;
	esac

	local count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" -eq 0 ]] && { printf '0'; return 0; }

	case "$method" in
		mean)
			printf '%s' "$verdicts" | jq -r '[.[].score] | add / length'
			;;
		weighted_mean)
			local weighted
			weighted=$(printf '%s' "$verdicts" | jq -r \
				--argjson rubric "$rubric" --argjson mincov "$min_coverage" '
				. as $v
				| ([ ($rubric.criteria // [])[]
				     | select((.weight | type) == "number") | .weight ] | add) as $total_w
				| [ ($rubric.criteria // [])[]
				    | select((.name | type) == "string" and (.weight | type) == "number")
				    | . as $c
				    | ([ $v[]
				         | select((.criterion_scores | type) == "object")
				         | select(.criterion_scores | has($c.name))
				         | .criterion_scores[$c.name]
				         | select(type == "number" and . >= 0 and . <= 1) ]) as $scores
				    | select(($scores | length) > 0)
				    | { w: $c.weight, m: (($scores | add) / ($scores | length)) } ] as $covered
				| [ ($rubric.criteria // [])[]
				    | select((.name | type) == "string" and (.min_pass | type) == "number")
				    | . as $c
				    | select([ $v[]
				               | select((.criterion_scores | type) == "object")
				               | select(.criterion_scores | has($c.name))
				               | .criterion_scores[$c.name]
				               | select(type == "number" and . >= 0 and . <= 1) ] | length == 0)
				    | $c.name ] as $unscored_floors
				| ($covered | map(.w) | add) as $den
				| if ($covered | length) == 0 or $den == null or $den <= 0 then empty
				  elif $total_w == null or $total_w <= 0 then empty
				  elif ($unscored_floors | length) > 0 then empty
				  elif ($den / $total_w) < $mincov then empty
				  else ($covered | map(.w * .m) | add) / $den
				  end
			' 2>/dev/null)
			if [ -n "$weighted" ]; then
				printf '%s' "$weighted"
			else
				# No criterion carried a usable score, or the panel covered too
				# little of the rubric to renormalize honestly — degrade to mean.
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

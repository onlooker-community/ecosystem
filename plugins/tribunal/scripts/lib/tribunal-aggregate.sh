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
# weighted_mean uses *rubric criterion weights*, not per-judge weights — the
# semantics are "weight each criterion's contribution, then average judges'
# scores on each criterion." For v0.1 the per-criterion breakdown is not yet
# threaded through verdicts, so weighted_mean degrades to mean when the rubric
# weights cannot be applied. The schema still emits aggregation_method =
# "weighted_mean" so dashboards see the intent.

tribunal_aggregate() {
	local method="${1:-mean}"
	local verdicts="${2:-[]}"
	local _rubric="${3:-{}}"  # reserved for true weighted_mean once per-criterion scores are threaded
	: "$_rubric"

	local count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" -eq 0 ]] && { printf '0'; return 0; }

	case "$method" in
		mean|weighted_mean)
			printf '%s' "$verdicts" | jq -r '[.[].score] | add / length'
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

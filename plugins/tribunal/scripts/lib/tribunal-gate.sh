#!/usr/bin/env bash
# Gate decision for Tribunal.
#
# Resolves a gate verdict (passed | blocked + reason) from the four schema
# gate_policy values: strict, majority, unanimous, meta_override.
#
# Each policy operates over:
#   - verdicts: JSON array of { judge_id, score, passed } from each Judge
#   - aggregated_score: float, output of tribunal_aggregate
#   - score_threshold: float from the active rubric
#   - meta: JSON of the Meta-Judge's TribunalMetaCompletePayload (for bias_detected
#           and override_recommendation)
#   - dissent_score: float, output of tribunal_disagreement
#   - dissent_threshold: float from rubric/config
#
# Echoes a JSON object: { passed: bool, reason?: string }
#   reason is one of: low_score | meta_override | bias_detected | dissent_unresolved
#                   | criterion_floor  (with failed_criterion naming the criterion)
#
# Usage: result=$(tribunal_gate_decide "$policy" "$verdicts" "$agg" "$thr" "$meta" "$dissent" "$dissent_thr")

tribunal_gate_decide() {
	local policy="${1:-majority}"
	local verdicts="${2:-[]}"
	local aggregated_score="${3:-0}"
	local score_threshold="${4:-0.75}"
	local meta="${5:-}"
	[ -z "$meta" ] && meta='{}'
	local dissent_score="${6:-0}"
	local dissent_threshold="${7:-0.25}"
	local rubric="${8:-}"
	[ -z "$rubric" ] && rubric='{}'

	local meta_bias_detected meta_override
	meta_bias_detected=$(printf '%s' "$meta" | jq -r '.bias_detected // false' 2>/dev/null)
	meta_override=$(printf '%s' "$meta" | jq -r '.override_recommendation // empty' 2>/dev/null)

	# meta_override policy: the Meta-Judge wins, regardless of jury.
	if [[ "$policy" == "meta_override" ]]; then
		case "$meta_override" in
			accept)
				printf '{"passed":true}'
				return 0
				;;
			reject)
				printf '{"passed":false,"reason":"meta_override"}'
				return 0
				;;
			re-evaluate|"")
				# No clear override → fall through to score-based decision.
				;;
		esac
	fi

	# Bias detection short-circuit (any policy).
	if [[ "$meta_bias_detected" == "true" && "$meta_override" == "reject" ]]; then
		printf '{"passed":false,"reason":"bias_detected"}'
		return 0
	fi

	# Dissent short-circuit: if judges disagree past threshold AND the Meta-Judge
	# has not provided an override, block with dissent_unresolved so the loop
	# retries with a fresh Actor pass.
	if awk -v d="$dissent_score" -v t="$dissent_threshold" 'BEGIN { exit !(d > t) }' \
		&& [[ -z "$meta_override" || "$meta_override" == "re-evaluate" ]]; then
		printf '{"passed":false,"reason":"dissent_unresolved"}'
		return 0
	fi

	local count passed_count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	passed_count=$(printf '%s' "$verdicts" | jq '[.[] | select(.passed == true)] | length' 2>/dev/null) || passed_count=0

	local jury_ok=1  # 0 = ok, 1 = not ok (shell convention)
	case "$policy" in
		strict|unanimous)
			[[ "$count" -gt 0 && "$passed_count" -eq "$count" ]] && jury_ok=0
			;;
		majority)
			# strictly greater than half
			[[ "$count" -gt 0 ]] && (( passed_count * 2 > count )) && jury_ok=0
			;;
		meta_override)
			# Already handled accept/reject above; fall back to majority for the
			# re-evaluate / unset case.
			[[ "$count" -gt 0 ]] && (( passed_count * 2 > count )) && jury_ok=0
			;;
		*)
			printf 'tribunal-gate: unknown policy %s, falling back to majority\n' \
				"$policy" >&2
			[[ "$count" -gt 0 ]] && (( passed_count * 2 > count )) && jury_ok=0
			;;
	esac

	local score_ok=1
	awk -v s="$aggregated_score" -v t="$score_threshold" 'BEGIN { exit !(s >= t) }' && score_ok=0

	# Per-criterion floors. A criterion whose mean across the judges that scored
	# it falls below min_pass blocks regardless of the aggregate or the policy —
	# that is the whole point of a floor.
	#
	# A criterion no judge scored is NOT a violation: absence is not a zero, and
	# treating it as one would fail every verdict emitted before judges shipped
	# criterion_scores. It is reported on stderr instead, because a floor nobody
	# scores is a silent hole in the rubric.
	local floor_failed unscored_floors any_scored
	any_scored=$(printf '%s' "$verdicts" | jq -r '
		[.[] | select((.criterion_scores | type) == "object")
		     | select((.criterion_scores | length) > 0)] | length > 0
	' 2>/dev/null) || any_scored="false"

	floor_failed=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
		. as $v
		| [ ($rubric.criteria // [])[]
		    | select((.name | type) == "string" and (.min_pass | type) == "number")
		    | . as $c
		    | ([ $v[]
		         | select((.criterion_scores | type) == "object")
		         | select(.criterion_scores | has($c.name))
		         | .criterion_scores[$c.name]
		         | select(type == "number") ]) as $scores
		    | select(($scores | length) > 0)
		    | select((($scores | add) / ($scores | length)) < $c.min_pass)
		    | $c.name ]
		| first // empty
	' 2>/dev/null) || floor_failed=""

	if [[ "$any_scored" == "true" ]]; then
		unscored_floors=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
			. as $v
			| [ ($rubric.criteria // [])[]
			    | select((.name | type) == "string" and (.min_pass | type) == "number")
			    | . as $c
			    | select([ $v[]
			               | select((.criterion_scores | type) == "object")
			               | select(.criterion_scores | has($c.name))
			               | .criterion_scores[$c.name]
			               | select(type == "number") ] | length == 0)
			    | $c.name ]
			| join(", ")
		' 2>/dev/null) || unscored_floors=""
		if [[ -n "$unscored_floors" ]]; then
			printf 'tribunal-gate: no judge scored these criteria, so their min_pass floors did not apply: %s\n' \
				"$unscored_floors" >&2
		fi
	fi

	# Pick the most informative blocking reason. low_score first: if the
	# aggregate missed the threshold, that is the more actionable thing to tell
	# the Actor than any single criterion.
	if [[ "$score_ok" -ne 0 ]]; then
		printf '{"passed":false,"reason":"low_score"}'
	elif [[ -n "$floor_failed" ]]; then
		printf '{"passed":false,"reason":"criterion_floor","failed_criterion":"%s"}' "$floor_failed"
	elif [[ "$jury_ok" -ne 0 ]]; then
		if [[ "$meta_override" == "reject" ]]; then
			printf '{"passed":false,"reason":"meta_override"}'
		else
			printf '{"passed":false,"reason":"dissent_unresolved"}'
		fi
	else
		printf '{"passed":true}'
	fi
}

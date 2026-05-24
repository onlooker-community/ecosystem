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
#
# Usage: result=$(tribunal_gate_decide "$policy" "$verdicts" "$agg" "$thr" "$meta" "$dissent" "$dissent_thr")

tribunal_gate_decide() {
	local policy="${1:-majority}"
	local verdicts="${2:-[]}"
	local aggregated_score="${3:-0}"
	local score_threshold="${4:-0.75}"
	local meta="${5:-{}}"
	local dissent_score="${6:-0}"
	local dissent_threshold="${7:-0.25}"

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

	if [[ "$jury_ok" -eq 0 && "$score_ok" -eq 0 ]]; then
		printf '{"passed":true}'
		return 0
	fi

	# Pick the most informative blocking reason.
	if [[ "$score_ok" -ne 0 ]]; then
		printf '{"passed":false,"reason":"low_score"}'
	else
		# Jury did not pass even though score cleared threshold — surface as
		# meta_override when meta said reject, else dissent_unresolved.
		if [[ "$meta_override" == "reject" ]]; then
			printf '{"passed":false,"reason":"meta_override"}'
		else
			printf '{"passed":false,"reason":"dissent_unresolved"}'
		fi
	fi
}

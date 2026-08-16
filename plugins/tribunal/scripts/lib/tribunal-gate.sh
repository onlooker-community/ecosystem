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
# Usage: result=$(tribunal_gate_decide "$policy" "$verdicts" "$agg" "$thr" "$meta" "$dissent" "$dissent_thr" "$rubric")

# Names the first criterion sitting below its min_pass, or echoes nothing.
#
# The *lowest* score among the judges that scored it, not the mean: a floor
# means nobody may be below it. Using the mean let a specialist's finding be
# diluted by generalists who did not look — with safety floored at 0.8, a
# security judge scoring 0.6 against two generalists at 0.95 averaged to 0.83
# and passed, so empanelling more judges made every floor weaker. Weighting
# still uses the mean; only the floor is a minimum.
#
# A criterion no judge scored is NOT a violation: absence is not a zero, and
# treating it as one would fail every verdict emitted before judges shipped
# criterion_scores. tribunal_aggregate degrades weighted_mean to the plain mean
# when that happens, and the caller warns on stderr.
#
# A criterion a judge DID score but scored unreadably — outside [0,1], or not a
# number — is a different thing, and it is a violation. Absence means the judge
# declined to assess (the agents are told to omit what they cannot judge);
# unreadable means they assessed it and the answer did not survive. A floor is
# the rubric's hard constraint, so "cannot confirm this held" must fail closed.
#
# ANY unreadable report violates, not merely an all-unreadable criterion, and
# that follows from why the floor uses min rather than mean in the first place:
# a specialist's finding must not be diluted by generalists who did not look.
# Merely filtering the bad value reproduces the exact dilution this design was
# built to prevent — a security judge emitting 30 (plausibly 0.30, a violation)
# would be discarded so two generalists at 0.95 carry the floor.
#
# The range test matches _tribunal_usable_verdicts in tribunal-aggregate.sh and
# the criterion filter in weighted_mean. Those disagreeing is what let an
# out-of-range score satisfy a floor while aggregation refused to score it at
# all — see ecosystem-5fy.
#
# Private to this file. It exists as a function because the answer is needed in
# two places — once to veto `meta_override: accept`, once for the blocking
# precedence chain — and duplicating the jq is how the two drift apart.
_tribunal_floor_failed() {
	local verdicts="${1:-[]}"
	local rubric="${2:-}"
	[ -z "$rubric" ] && rubric='{}'
	printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
		def readable: (type == "number") and . >= 0 and . <= 1;
		. as $v
		| [ ($rubric.criteria // [])[]
		    | select((.name | type) == "string" and (.min_pass | type) == "number")
		    | . as $c
		    | ([ $v[]
		         | select((.criterion_scores | type) == "object")
		         | select(.criterion_scores | has($c.name))
		         | .criterion_scores[$c.name] ]) as $reported
		    | ([ $reported[] | select(readable) ]) as $scores
		    | select(
		        # somebody reported a score this scale cannot read...
		        ($reported | length) > ($scores | length)
		        # ...or the readable ones put somebody under the floor.
		        or (($scores | length) > 0 and ($scores | min) < $c.min_pass)
		      )
		    | $c.name ]
		| first // empty
	' 2>/dev/null || printf ''
}

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

	# Which criterion, if any, sits below its floor. Computed here rather than
	# beside the other blocking reasons because `meta_override: accept` returns
	# before them, and a floor the Meta-Judge can lift is not a floor. See the
	# longer note on min-not-mean further down.
	local floor_failed
	floor_failed=$(_tribunal_floor_failed "$verdicts" "$rubric")

	# meta_override policy: the Meta-Judge wins, regardless of jury.
	if [[ "$policy" == "meta_override" ]]; then
		case "$meta_override" in
			accept)
				# ...but not regardless of the rubric. `accept` overrules the
				# jury's *opinion*; a floor is the rubric's hard constraint, so
				# it survives. Every other short-circuit below already blocks,
				# which made this the one arm that could turn a violated floor
				# into a pass.
				if [[ -n "$floor_failed" ]]; then
					printf '{"passed":false,"reason":"criterion_floor","failed_criterion":"%s"}' "$floor_failed"
					return 0
				fi
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

	# A verdict tribunal_aggregate refuses to score cannot vote to approve, but
	# its SEAT STILL COUNTS. The usability test below is the same one
	# _tribunal_usable_verdicts applies in tribunal-aggregate.sh — a numeric
	# score inside [0,1], so a judge emitting 95 instead of 0.95 is as unusable
	# as one that emitted nothing. The two copies must stay in step, and
	# "usable verdicts agree with tribunal_aggregate" in the bats file is what
	# catches them drifting.
	#
	# Denying the vote rather than dropping the verdict is deliberate, and it
	# is NOT what ecosystem-y7y originally asked for. Making both halves agree
	# on panel membership sounds right and loosens the gate: dropping shrinks
	# the panel, and a shrunken panel is a trivially satisfied majority. One
	# real approval beside two verdicts that never arrived would become a
	# 1-of-1 pass, and strict would clear on a panel that never fully reported
	# — the hazard librarian's judge-type check exists to prevent. Measured
	# across the five reachable cases, dropping fixed one and loosened three.
	#
	# A judge that failed to return a verdict did not leave the panel; it
	# failed. So majority still needs a majority of everyone empaneled, and
	# strict still needs all of them.
	local count passed_count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	passed_count=$(printf '%s' "$verdicts" | jq '
		def usable: (.score | type) == "number" and .score >= 0 and .score <= 1;
		[.[] | select(.passed == true and usable)] | length
	' 2>/dev/null) || passed_count=0

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

	# A floor nobody scored is a silent hole in the rubric, so say so. The gate
	# does not block on it — see _tribunal_floor_failed for why absence is not a
	# zero — but tribunal_aggregate has already refused to renormalize around it,
	# so the aggregate this gate just judged is the panel's plain mean.
	#
	# ABSENCE ONLY: this names criteria nobody reported, not ones reported
	# unreadably. Those now violate the floor and block, so naming them here
	# would print "their min_pass floors did not apply" about a floor that did
	# apply and did block. The two also cannot share a predicate: conflating
	# them meant the sole signal for "a floor got skipped" was emitted by the
	# very defect that skipped it, which is how this stayed quiet.
	local unscored_floors any_scored
	any_scored=$(printf '%s' "$verdicts" | jq -r '
		[.[] | select((.criterion_scores | type) == "object")
		     | select((.criterion_scores | length) > 0)] | length > 0
	' 2>/dev/null) || any_scored="false"

	if [[ "$any_scored" == "true" ]]; then
		unscored_floors=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
			. as $v
			| [ ($rubric.criteria // [])[]
			    | select((.name | type) == "string" and (.min_pass | type) == "number")
			    | . as $c
			    | select([ $v[]
			               | select((.criterion_scores | type) == "object")
			               | select(.criterion_scores | has($c.name))
			               | .criterion_scores[$c.name] ] | length == 0)
			    | $c.name ]
			| join(", ")
		' 2>/dev/null) || unscored_floors=""
		if [[ -n "$unscored_floors" ]]; then
			printf 'tribunal-gate: no judge scored these criteria, so their min_pass floors did not apply: %s\n' \
				"$unscored_floors" >&2
		fi
	fi

	# A violated floor is worth naming whichever reason wins the precedence
	# contest below: the worst failures drag the aggregate under the threshold
	# too, so attaching failed_criterion only to the criterion_floor arm left
	# the diagnostic absent exactly where it mattered most.
	local floor_suffix=""
	[[ -n "$floor_failed" ]] && floor_suffix=$(printf ',"failed_criterion":"%s"' "$floor_failed")

	# Pick the most informative blocking reason. Every arm here blocks — this
	# chain only decides what the Actor is TOLD, never whether the work passes.
	# Keeping those two apart is the whole basis for the order:
	#
	#   low_score           — the aggregate missed the threshold, which is more
	#                         actionable than any single criterion.
	#   jury arms           — WHY the panel failed. A Meta-Judge rejection is
	#                         the more useful thing to hand back on retry than
	#                         which criterion sat low, and the floor still rides
	#                         along as failed_criterion.
	#   criterion_floor     — no jury complaint, so the floor IS the complaint.
	#
	# The jury arms sit ahead of criterion_floor deliberately (ecosystem-4d3),
	# matching librarian's shipped decision — "lesson gate: jury policy still
	# wins over criterion_floor". This does not weaken floors: a violated floor
	# still blocks on the arm below, and `meta_override: accept` still cannot
	# lift one, because that veto lives further up and returns before any of
	# this. What changed is only that a floor no longer HIDES a rejection.
	#
	# Ordering it the other way is what made floor_suffix on the jury arms dead
	# code (ecosystem-cs8): behind `elif [[ -n $floor_failed ]]`, floor_failed
	# was guaranteed empty by the time those arms ran, so the suffix always
	# rendered as the empty string while two shipped docs described it working.
	#
	# The tests under "blocking-reason precedence" pin every arm. Nothing pinned
	# them before, which is how a new arm went in ahead of two others under a
	# comment asserting the precedence was unchanged.
	if [[ "$score_ok" -ne 0 ]]; then
		printf '{"passed":false,"reason":"low_score"%s}' "$floor_suffix"
	elif [[ "$jury_ok" -ne 0 ]]; then
		if [[ "$meta_override" == "reject" ]]; then
			printf '{"passed":false,"reason":"meta_override"%s}' "$floor_suffix"
		else
			printf '{"passed":false,"reason":"dissent_unresolved"%s}' "$floor_suffix"
		fi
	elif [[ -n "$floor_failed" ]]; then
		printf '{"passed":false,"reason":"criterion_floor","failed_criterion":"%s"}' "$floor_failed"
	else
		printf '{"passed":true}'
	fi
}

#!/usr/bin/env bats

# `run --separate-stderr` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-gate.sh"
}

ALL_PASSED='[{"judge_id":"a","score":0.85,"passed":true},{"judge_id":"b","score":0.80,"passed":true}]'
ONE_FAILED='[{"judge_id":"a","score":0.85,"passed":true},{"judge_id":"b","score":0.40,"passed":false}]'
ALL_FAILED='[{"judge_id":"a","score":0.30,"passed":false},{"judge_id":"b","score":0.40,"passed":false}]'
NO_META='{}'

@test "strict: all judges pass + score >= threshold → passed" {
	local out
	out=$(tribunal_gate_decide "strict" "$ALL_PASSED" "0.82" "0.75" "$NO_META" "0.05" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "true" ]
}

@test "strict: one judge fails → blocked with dissent_unresolved or low_score" {
	local out
	out=$(tribunal_gate_decide "strict" "$ONE_FAILED" "0.62" "0.75" "$NO_META" "0.45" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ]
	# dissent + no meta override → dissent_unresolved
	[ "$(printf '%s' "$out" | jq -r '.reason')" = "dissent_unresolved" ]
}

@test "majority: more than half pass + score clears → passed" {
	local three='[{"judge_id":"a","score":0.9,"passed":true},{"judge_id":"b","score":0.8,"passed":true},{"judge_id":"c","score":0.4,"passed":false}]'
	local out
	out=$(tribunal_gate_decide "majority" "$three" "0.78" "0.75" "$NO_META" "0.20" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "true" ]
}

@test "majority: split 1-1 with low score → blocked low_score" {
	local out
	out=$(tribunal_gate_decide "majority" "$ONE_FAILED" "0.62" "0.75" "$NO_META" "0.20" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$out" | jq -r '.reason')" = "low_score" ]
}

@test "unanimous: identical to strict when count > 1" {
	local out
	out=$(tribunal_gate_decide "unanimous" "$ALL_PASSED" "0.82" "0.75" "$NO_META" "0.05" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "true" ]

	out=$(tribunal_gate_decide "unanimous" "$ONE_FAILED" "0.62" "0.75" "$NO_META" "0.05" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ]
}

@test "meta_override accept beats failing jury" {
	local meta='{"override_recommendation":"accept","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "meta_override" "$ALL_FAILED" "0.30" "0.75" "$meta" "0.10" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "true" ]
}

@test "meta_override reject blocks even with passing jury" {
	local meta='{"override_recommendation":"reject","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "meta_override" "$ALL_PASSED" "0.82" "0.75" "$meta" "0.05" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$out" | jq -r '.reason')" = "meta_override" ]
}

@test "bias_detected + meta says reject → bias_detected reason" {
	local meta='{"override_recommendation":"reject","bias_detected":true,"bias_types":["verbosity"]}'
	local out
	out=$(tribunal_gate_decide "majority" "$ONE_FAILED" "0.60" "0.75" "$meta" "0.45" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$out" | jq -r '.reason')" = "bias_detected" ]
}

@test "dissent above threshold + no meta override → dissent_unresolved" {
	local meta='{"bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "majority" "$ONE_FAILED" "0.62" "0.50" "$meta" "0.45" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$out" | jq -r '.reason')" = "dissent_unresolved" ]
}

@test "score clears threshold but jury says no → meta_override or dissent reason" {
	# All judges marked passed=false but aggregated_score is above threshold
	# (contrived to exercise the "score_ok + jury_fail" branch).
	local odd='[{"judge_id":"a","score":0.9,"passed":false},{"judge_id":"b","score":0.8,"passed":false}]'
	local meta='{"override_recommendation":"reject","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "majority" "$odd" "0.85" "0.75" "$meta" "0.10" "0.25")
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$out" | jq -r '.reason')" = "meta_override" ]
}

RUBRIC_FLOOR='{"criteria":[{"name":"correctness","weight":0.5,"min_pass":0.7},{"name":"safety","weight":0.5,"min_pass":0.8}]}'

@test "a criterion below its floor blocks even when score and jury both pass" {
	# This is the property that does not exist today: aggregate 0.82 clears the
	# 0.75 threshold, both judges passed, and the gate blocks anyway.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "meta_override accept cannot lift a criterion below its floor" {
	# `accept` returned before the floor check ever ran, so one gate policy
	# defeated every floor in the rubric. A floor is not the jury's opinion for
	# the Meta-Judge to overrule — it is the rubric's hard constraint, and the
	# function's own contract is that it blocks regardless of the policy.
	local meta='{"override_recommendation":"accept","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "meta_override" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.82" "0.75" "$meta" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "meta_override accept still overrules a failing jury when the floors hold" {
	# The veto above must stay narrow: `accept` beating a jury that voted no is
	# the whole purpose of the policy, and only a *violated* floor may stop it.
	local meta='{"override_recommendation":"accept","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "meta_override" '[
	  {"judge_id":"a","score":0.30,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.95}},
	  {"judge_id":"b","score":0.40,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.95}}
	]' "0.30" "0.75" "$meta" "0.10" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "a criterion at exactly its floor passes" {
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.7,"safety":0.8}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.7,"safety":0.8}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "a verdict with no criterion_scores key at all never blocks" {
	# Every verdict emitted before Task 1 shipped. Treating absence as violation
	# would make every pre-upgrade judge fail every rubric carrying a floor.
	# Caught by the outer `criterion_scores | type == "object"` guard — this
	# case never reaches has(), so it does not pin the has() guard itself.
	local out
	out=$(tribunal_gate_decide "majority" "$ALL_PASSED" "0.82" "0.75" \
		"$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "scores present but a floored criterion omitted does not block" {
	# THE test that pins the has() guard. These verdicts DO carry
	# criterion_scores, so they survive the outer type guard and reach the
	# per-criterion lookup — but `safety`, whose floor is 0.8, is absent.
	# Substituting `// 0` for has() makes safety read as 0.0 and blocks.
	#
	# Its own test because the case above cannot fail when has() is deleted:
	# that fixture is filtered one layer earlier. Two different absences
	# sharing one test is how an outer guard silently stands in for an inner.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "a criterion scored exactly zero does block" {
	# The mirror of the previous test. A fix that conflates absent with zero
	# passes one of these two and fails the other.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.0}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.0}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "a hyphenated criterion name gates correctly" {
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"path-traversal":0.1}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"path-traversal":0.1}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" \
	'{"criteria":[{"name":"path-traversal","weight":1.0,"min_pass":0.5}]}')
	printf '%s' "$out" | jq -e '.failed_criterion == "path-traversal"' >/dev/null
}

@test "low_score still wins over criterion_floor" {
	# Precedence matters for the retry digest: if the aggregate missed the
	# threshold, that is the more actionable thing to tell the Actor.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.20,"passed":true,"criterion_scores":{"correctness":0.1,"safety":0.1}},
	  {"judge_id":"b","score":0.20,"passed":true,"criterion_scores":{"correctness":0.1,"safety":0.1}}
	]' "0.20" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "low_score"' >/dev/null
}

@test "a floor uses the lowest judge score, not the mean" {
	# A specialist's finding must not be dilutable by generalists who did not
	# look. safety's floor is 0.8; the mean of 0.95/0.95/0.6 is 0.833 and used
	# to pass.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.9,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.95}},
	  {"judge_id":"b","score":0.9,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.95}},
	  {"judge_id":"c","score":0.9,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.6}}
	]' "0.9" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "a low_score block still names the criterion that failed its floor" {
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.2,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.1}},
	  {"judge_id":"b","score":0.2,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.1}}
	]' "0.20" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "low_score"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "a floor on a criterion no judge scored is reported on stderr" {
	# The adversarial-judge gap: safety carries the highest floor and appeared
	# in no agent contract. Silently passing a floor nobody scored is this
	# design's own failure mode one layer down.
	run --separate-stderr tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR"
	printf '%s' "$output" | jq -e '.passed == true' >/dev/null || return 1
	local re='safety'
	[[ "$stderr" =~ $re ]]
}

@test "no unscored-criterion warning when no judge scored anything" {
	# The pre-upgrade fleet must not spew a warning on every single gate.
	run --separate-stderr tribunal_gate_decide "majority" "$ALL_PASSED" "0.82" "0.75" \
		"$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR"
	[ -z "$stderr" ]
}

@test "the gate still works with no rubric at all" {
	local out
	out=$(tribunal_gate_decide "majority" "$ALL_PASSED" "0.82" "0.75" "$NO_META" "0.05" "0.25")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

# --- Verdicts the aggregate refuses to score (ecosystem-y7y) ----------------
#
# tribunal_aggregate drops a verdict with no numeric .score (ecosystem-up8),
# but the jury counted .passed over the raw panel, so a verdict that
# contributed nothing to the aggregate could still vote.
#
# The fix denies the vote and KEEPS THE SEAT. Dropping the verdict outright —
# making both halves agree on membership, which is what this bead originally
# asked for — shrinks the panel, and a shrunken panel is a trivially satisfied
# majority. That is the hazard librarian's judge-type check exists to prevent,
# so the naive reading of "agree on membership" would have loosened the gate
# in three cases while fixing one. A judge that failed to return a verdict did
# not leave the panel; it failed.

@test "a verdict with no usable score cannot cast a passing vote" {
	# The verified fail-open: the only judge that actually returned a verdict
	# rejected the work, and two malformed verdicts supplied the majority.
	#
	# The fixture is asserted well-formed first. An earlier draft of this test
	# built the panel by string-concatenating a fixture variable and produced
	# invalid JSON, which made jq fail and passed_count fall back to 0 — so it
	# passed while proving nothing, whether or not the guard existed.
	local panel='[
	  {"judge_id":"real","score":0.9,"passed":false},
	  {"judge_id":"bad1","passed":true},
	  {"judge_id":"bad2","passed":true}
	]'
	printf '%s' "$panel" | jq -e 'length == 3' >/dev/null || return 1

	local out
	out=$(tribunal_gate_decide "majority" "$panel" "0.90" "0.75" "$NO_META" "0.05" "0.25")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null
}

@test "a malformed verdict keeps its seat, so a thin panel is not a trivial majority" {
	# One real approval plus two verdicts that never arrived is not a majority
	# of a three-judge panel. Filtering them out would make it one.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"real","score":0.9,"passed":true},
	  {"judge_id":"bad1","passed":false},
	  {"judge_id":"bad2","passed":false}
	]' "0.90" "0.75" "$NO_META" "0.05" "0.25")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null
}

@test "strict blocks when any judge returned no usable verdict" {
	# strict means every judge passed. A judge that returned nothing did not.
	local out
	out=$(tribunal_gate_decide "strict" '[
	  {"judge_id":"a","score":0.9,"passed":true},
	  {"judge_id":"b","score":0.8,"passed":true},
	  {"judge_id":"bad","passed":true}
	]' "0.85" "0.75" "$NO_META" "0.05" "0.25")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null
}

@test "a malformed verdict does not block a genuine majority" {
	# The guard must not overreach: two real approvals out of three still carry
	# a majority gate, exactly as before.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.9,"passed":true},
	  {"judge_id":"b","score":0.8,"passed":true},
	  {"judge_id":"bad","passed":true}
	]' "0.85" "0.75" "$NO_META" "0.05" "0.25")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "usable verdicts agree with tribunal_aggregate" {
	# The gate and tribunal_aggregate each carry their own copy of "is this
	# verdict usable", in different files, with nothing keeping them in step.
	# This pins the equivalence behaviorally rather than by comparing source.
	#
	# A single-judge panel makes both answers observable: majority needs one
	# passing vote, and the aggregate of a lone unusable verdict is 0.
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-aggregate.sh"

	local shape agg out kept votable
	for shape in \
		'{"judge_id":"a","score":0.9,"passed":true}' \
		'{"judge_id":"a","passed":true}' \
		'{"judge_id":"a","score":"high","passed":true}' \
		'{"judge_id":"a","score":null,"passed":true}' \
		'{"judge_id":"a","score":100,"passed":true}' \
		'{"judge_id":"a","score":-5,"passed":true}' \
		'{"judge_id":"a","score":1,"passed":true}'
	do
		# Does the aggregate keep it? A kept verdict yields its own score.
		agg=$(tribunal_aggregate "mean" "[$shape]" 2>/dev/null)
		kept=$(awk -v a="$agg" 'BEGIN { print (a > 0.5) ? "yes" : "no" }')

		# Does the gate let it vote? Handed an aggregate that clears the
		# threshold, a one-judge majority turns entirely on the vote.
		out=$(tribunal_gate_decide "majority" "[$shape]" "0.90" "0.75" \
			"$NO_META" "0.0" "0.25" 2>/dev/null)
		votable=$(printf '%s' "$out" | jq -r 'if .passed then "yes" else "no" end')

		[ "$kept" = "$votable" ] || {
			printf 'drift on %s: aggregate kept=%s, gate votable=%s\n' \
				"$shape" "$kept" "$votable" >&2
			return 1
		}
	done
}

# --- out-of-range verdict scores (ecosystem-7cl) --------------------------

@test "a whole panel of out-of-range scores cannot pass the gate" {
	# Three judges all reporting 95-instead-of-0.95. Pre-fix the aggregate
	# trusted them, so every threshold cleared. The scores are deliberately
	# IDENTICAL: a spread of out-of-range scores blocks on dissent instead, so
	# the mixed panel would pass this test with the bug still in place. Only a
	# unanimous out-of-range panel — dissent 0, nothing left to catch it — is
	# the actual fail-open.
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-aggregate.sh"

	local panel='[{"judge_id":"a","score":95,"passed":true},{"judge_id":"b","score":95,"passed":true},{"judge_id":"c","score":95,"passed":true}]'
	local agg dissent out
	agg=$(tribunal_aggregate "mean" "$panel" 2>/dev/null)
	dissent=$(tribunal_disagreement "$panel" 2>/dev/null)
	out=$(tribunal_gate_decide "majority" "$panel" "$agg" "0.75" "$NO_META" "$dissent" "0.25" 2>/dev/null)

	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ]
}

@test "an out-of-range verdict keeps its seat, so it cannot be voted around" {
	# Same rule y7y settled for scoreless verdicts: a judge whose verdict was
	# refused did not leave the panel, it failed. Two real approvals beside one
	# out-of-range verdict is 2-of-3, not 2-of-2.
	local panel='[{"judge_id":"a","score":0.9,"passed":true},{"judge_id":"b","score":0.85,"passed":true},{"judge_id":"c","score":100,"passed":true}]'
	local out
	out=$(tribunal_gate_decide "strict" "$panel" "0.87" "0.75" "$NO_META" "0.05" "0.25" 2>/dev/null)
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "false" ] || return 1

	# ...and majority, which two of three genuinely satisfies, still passes.
	out=$(tribunal_gate_decide "majority" "$panel" "0.87" "0.75" "$NO_META" "0.05" "0.25" 2>/dev/null)
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "true" ]
}

@test "a verdict scored 0 still casts its vote" {
	# [0,1] is inclusive at both ends. 0 is a real verdict — the judge scored
	# the work and scored it badly — so it must not be swept up with the
	# malformed ones. Pinned at the gate because the drift-guard loop below
	# infers usability from the aggregate clearing 0.5 and cannot see this.
	local out
	out=$(tribunal_gate_decide "strict" \
		'[{"judge_id":"a","score":0,"passed":true}]' "0.90" "0.75" \
		"$NO_META" "0.0" "0.25" 2>/dev/null)
	[ "$(printf '%s' "$out" | jq -r '.passed')" = "true" ]
}

# --- out-of-range criterion scores (ecosystem-5fy) ------------------------
#
# A floor is the rubric's hard constraint: nobody may be below it. An
# unreadable report on a floored criterion means we cannot confirm that held,
# and "cannot confirm" on a hard constraint has to fail closed.

@test "an out-of-range criterion score cannot satisfy its floor" {
	# THE verified case. safety 0.30 against an 0.8 floor blocks; the identical
	# judgment written as 30 used to pass clean, because 30 < 0.8 is false.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":30}},
	  {"judge_id":"b","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":30}}
	]' "0.85" "0.75" "$NO_META" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "one judge's unreadable floor score is not diluted by judges who scored it fine" {
	# The dilution failure the floor design exists to prevent, reproduced
	# through a different mechanism. A security specialist emitting 30 — which
	# may well mean 0.30, a violation — must not be silently discarded so that
	# two generalists at 0.95 carry the floor. Filtering the bad value alone
	# gives min([0.95,0.95]) and passes, which is why filtering is not enough.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"sec","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":30}},
	  {"judge_id":"gen1","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.95}},
	  {"judge_id":"gen2","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.95}}
	]' "0.85" "0.75" "$NO_META" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "a non-numeric criterion score cannot satisfy its floor either" {
	# Unreadable is unreadable — a string is no more confirmable than a 30.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":"high"}},
	  {"judge_id":"b","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":"high"}}
	]' "0.85" "0.75" "$NO_META" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "an unreadable floor score is not reported as one nobody scored" {
	# The two are different and must not be conflated. The stderr warning says
	# the floor DID NOT APPLY — true when the criterion is absent, and a false
	# statement here, where it applied and blocked. Conflating them also means
	# the one signal for "a floor was skipped" is emitted by the same defect
	# that skipped it.
	run --separate-stderr tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":30}},
	  {"judge_id":"b","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":30}}
	]' "0.85" "0.75" "$NO_META" "0.0" "0.25" "$RUBRIC_FLOOR"
	printf '%s' "$output" | jq -e '.passed == false' >/dev/null || return 1
	local re='did not apply'
	[[ ! "$stderr" =~ $re ]]
}

@test "meta_override accept cannot lift a floor it cannot confirm" {
	# The accept-veto added in #152 exists because a floor is not the jury's
	# opinion to overrule. An unconfirmable floor must sit behind the same veto,
	# or the policy becomes a way to launder a malformed score into a pass.
	local meta='{"override_recommendation":"accept","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "meta_override" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":30}},
	  {"judge_id":"b","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":30}}
	]' "0.85" "0.75" "$meta" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "the range bounds stay usable for criterion scores too" {
	# [0,1] inclusive. A criterion scored exactly 0 already has its own test
	# above (it blocks); this pins the other end, where 1.0 must read as a
	# perfect score rather than as out-of-range garbage.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":1,"safety":1}},
	  {"judge_id":"b","score":0.85,"passed":true,"criterion_scores":{"correctness":1,"safety":1}}
	]' "0.85" "0.75" "$NO_META" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "readable criterion scores agree with tribunal_aggregate" {
	# The criterion-level twin of "usable verdicts agree with tribunal_aggregate".
	# weighted_mean's filter and _tribunal_floor_failed's `readable` live in
	# different files with nothing keeping them in step, and them disagreeing IS
	# ecosystem-5fy: aggregation refused to score 30 while the floor accepted it.
	#
	# Every shape below sits at or above the 0.7 floor when readable, so the
	# gate blocks on unreadability alone and the two answers are comparable:
	# a criterion the aggregate USED is exactly one the gate did not reject.
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-aggregate.sh"

	local rubric='{"criteria":[{"name":"correctness","weight":1.0,"min_pass":0.7}]}'
	local shape agg out used blocked
	for shape in '0.9' '1' '0.7' '100' '-1' '"high"' 'null'; do
		local panel
		panel="[{\"judge_id\":\"a\",\"score\":0.5,\"passed\":true,\"criterion_scores\":{\"correctness\":${shape}}}]"

		# Did the aggregate use the criterion? If it did, the result is the
		# criterion's own value; if it refused, weighted_mean degrades to the
		# plain mean of .score, which is 0.5.
		agg=$(tribunal_aggregate "weighted_mean" "$panel" "$rubric" 2>/dev/null)
		used=$(awk -v a="$agg" 'BEGIN { print (a == 0.5) ? "no" : "yes" }')

		# Did the gate reject it as unreadable? Handed an aggregate that clears
		# the threshold, only the floor check can block.
		out=$(tribunal_gate_decide "majority" "$panel" "0.90" "0.75" \
			"$NO_META" "0.0" "0.25" "$rubric" 2>/dev/null)
		blocked=$(printf '%s' "$out" | jq -r 'if .passed then "no" else "yes" end')

		[ "$used" != "$blocked" ] || {
			printf 'drift on correctness=%s: aggregate used=%s, gate blocked=%s\n' \
				"$shape" "$used" "$blocked" >&2
			return 1
		}
	done
}

# --- blocking-reason precedence (ecosystem-4d3) ---------------------------
#
# Nothing pinned the order of these arms, so it could be reshuffled silently —
# which is how criterion_floor came to sit ahead of the jury arms in #150 under
# a comment claiming precedence was unchanged. Librarian's sibling gate already
# settled this the other way ("lesson gate: jury policy still wins over
# criterion_floor"); tribunal now matches.
#
# The jury arms report WHY the panel failed. A floor still blocks, and the
# meta_override accept-veto still makes it unoverridable — those are about the
# OUTCOME. This chain only picks which reason to name, and a Meta-Judge
# rejection is the more actionable thing to hand the Actor on retry than which
# criterion sat low. The floor rides along as failed_criterion either way.

@test "a Meta-Judge rejection outranks a violated floor as the reason" {
	# The bead's verified case. Both block; the question is what the Actor is
	# told. Pre-fix this reported criterion_floor and the rejection vanished.
	local meta='{"override_recommendation":"reject","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.85" "0.75" "$meta" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.reason == "meta_override"' >/dev/null || return 1
	# ...and the floor is not lost, it decorates. This is ecosystem-cs8: the
	# suffix on this arm was unreachable dead code before the reorder.
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "an unresolved jury outranks a violated floor as the reason" {
	# The other jury arm, reached when no override was given and dissent sits
	# below threshold. Same rule, and the same previously-dead suffix.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.85" "0.75" "$NO_META" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.reason == "dissent_unresolved"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "criterion_floor is still the reason when the jury has no complaint" {
	# Demoting the arm must not make it unreachable. A floor violated while the
	# score clears and every judge passed is exactly the case criterion_floor
	# exists for, and it is the whole point of the rubric's hard constraint.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "low_score still outranks both, and still names the floor" {
	# The one arm whose position is NOT changing. Pinned so the reorder cannot
	# quietly take it along.
	local meta='{"override_recommendation":"reject","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.30,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.30,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.30" "0.75" "$meta" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "low_score"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

# --- failed_criterion on the short-circuit arms (ecosystem-973) -----------
#
# floor_failed is computed near the top of the function, but floor_suffix was
# not built until well below these three early returns, so they could not
# reference it however much they wanted to. The result was two behaviors behind
# one reason string: dissent_unresolved carried the criterion from the final
# chain and dropped it from the short-circuit, which is the part most likely to
# mislead someone reading gate.blocked events.
#
# A missing diagnostic, never a wrong verdict — none of these change whether
# the gate blocks, only what it says about why.

@test "meta_override reject names a violated floor" {
	local meta='{"override_recommendation":"reject","bias_detected":false}'
	local out
	out=$(tribunal_gate_decide "meta_override" '[
	  {"judge_id":"a","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.85" "0.75" "$meta" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "meta_override"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "bias_detected names a violated floor" {
	local meta='{"override_recommendation":"reject","bias_detected":true,"bias_types":["verbosity"]}'
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.85" "0.75" "$meta" "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "bias_detected"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "the dissent short-circuit names a violated floor, like its chain twin" {
	# THE inconsistency this bead is really about: the same reason string
	# behaving two ways depending on which return produced it.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.85" "0.75" "$NO_META" "0.90" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "dissent_unresolved"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "the short-circuit arms stay quiet when no floor was violated" {
	# The suffix must remain a decoration, not become noise. Absent is still the
	# right answer when there is nothing to name — and with the arms now
	# reporting it, an absent field finally means what it says.
	local out
	local clean='[
	  {"judge_id":"a","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.95}},
	  {"judge_id":"b","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.95}}
	]'
	out=$(tribunal_gate_decide "meta_override" "$clean" "0.85" "0.75" \
		'{"override_recommendation":"reject","bias_detected":false}' "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e 'has("failed_criterion") | not' >/dev/null || return 1

	out=$(tribunal_gate_decide "majority" "$clean" "0.85" "0.75" \
		'{"override_recommendation":"reject","bias_detected":true}' "0.0" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e 'has("failed_criterion") | not' >/dev/null || return 1

	out=$(tribunal_gate_decide "majority" "$clean" "0.85" "0.75" \
		"$NO_META" "0.90" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e 'has("failed_criterion") | not' >/dev/null
}

@test "every blocking arm that can see a violated floor names it" {
	# The property the individual tests add up to, asserted as one thing so a
	# newly-added arm that forgets the suffix is caught by an existing test
	# rather than needing someone to remember to write a new one.
	local panel='[
	  {"judge_id":"a","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.85,"passed":false,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]'
	local passing='[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]'
	local reject='{"override_recommendation":"reject","bias_detected":false}'
	local biased='{"override_recommendation":"reject","bias_detected":true}'

	# Args are passed positionally rather than packed into a delimited string.
	# An earlier version packed them and unpacked with eval, which stripped the
	# JSON's own quotes: meta parsed as empty, the meta_override policy fell
	# through to the chain, and two arms reported PASS without ever reaching the
	# return they were meant to exercise.
	_arm_names_floor() {
		local label="$1" policy="$2" verdicts="$3" agg="$4" meta="$5" dissent="$6"
		local out reason
		out=$(tribunal_gate_decide "$policy" "$verdicts" "$agg" "0.75" \
			"$meta" "$dissent" "0.25" "$RUBRIC_FLOOR")
		reason=$(printf '%s' "$out" | jq -r '.reason // "none"')
		# Guard the premise too: an arm that silently stopped being reachable
		# would otherwise "pass" this by never being the arm under test.
		[ "$reason" = "$label" ] || {
			printf 'expected reason %s, got %s: %s\n' "$label" "$reason" "$out" >&2
			return 1
		}
		printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null || {
			printf 'arm %s dropped failed_criterion: %s\n' "$reason" "$out" >&2
			return 1
		}
	}

	# final chain
	_arm_names_floor low_score          majority      "$panel"   0.30 "$NO_META" 0.0 || return 1
	_arm_names_floor meta_override      majority      "$panel"   0.85 "$reject"  0.0 || return 1
	_arm_names_floor dissent_unresolved majority      "$panel"   0.85 "$NO_META" 0.0 || return 1
	_arm_names_floor criterion_floor    majority      "$passing" 0.85 "$NO_META" 0.0 || return 1
	# short-circuit returns
	_arm_names_floor meta_override      meta_override "$panel"   0.85 "$reject"  0.0 || return 1
	_arm_names_floor bias_detected      majority      "$panel"   0.85 "$biased"  0.0 || return 1
	_arm_names_floor dissent_unresolved majority      "$panel"   0.85 "$NO_META" 0.90
}

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

#!/usr/bin/env bats

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

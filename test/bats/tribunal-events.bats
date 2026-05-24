#!/usr/bin/env bats

# Validates every emitted tribunal.* event against @onlooker-community/schema
# v2.1.0+. Builds a single event via the canonical emitter and asserts the
# resulting JSONL line passes validate().

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	# tribunal-events.sh looks up onlooker-event.mjs relative to its plugin
	# root, but tests set CLAUDE_PLUGIN_ROOT to plugins/tribunal — point the
	# wrapper at the ecosystem copy directly so it does not have to walk.
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-events.sh"

	export CLAUDE_SESSION_ID="bats-session-$$"
}

# Re-validate the latest event in the log against the schema.
_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

TASK_ID="01J000000000000000000000TS"
ITER_ID="01J000000000000000000000IT"
JUDGE_ID="01J000000000000000000000JJ"

@test "session.start validates" {
	local p
	p=$(jq -n --arg t "$TASK_ID" '{
		task_id: $t,
		judge_types: ["standard","adversarial"],
		gate_policy: "majority",
		score_threshold: 0.75,
		max_iterations: 3,
		actor_model_id: "claude-sonnet-4-6",
		judge_model_ids: ["claude-opus-4-7","claude-opus-4-7"],
		meta_model_id: "claude-opus-4-7"
	}')
	tribunal_emit_event "tribunal.session.start" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "iteration.start validates" {
	local p
	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" \
		'{task_id: $t, iteration_id: $i, iteration_number: 0, trigger: "initial"}')
	tribunal_emit_event "tribunal.iteration.start" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "actor.start + actor.complete validate" {
	local p
	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" \
		'{task_id: $t, iteration_id: $i, iteration_number: 0, actor_model_id: "claude-sonnet-4-6"}')
	tribunal_emit_event "tribunal.actor.start" "$p"
	_validate_latest_event

	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" \
		'{task_id: $t, success: true, duration_ms: 4200, iteration_id: $i, iteration_number: 0, artifact_kind: "patch", actor_model_id: "claude-sonnet-4-6"}')
	tribunal_emit_event "tribunal.actor.complete" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "jury.empaneled validates" {
	local p
	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" --arg j "$JUDGE_ID" '{
		task_id: $t,
		iteration_id: $i,
		judges: [
			{judge_id: $j, judge_type: "standard", model_id: "claude-opus-4-7"},
			{judge_id: ($j+"X"), judge_type: "adversarial", model_id: "claude-opus-4-7"}
		],
		panel_size: 2
	}')
	tribunal_emit_event "tribunal.jury.empaneled" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "judge.start + verdict validate" {
	local p
	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" --arg j "$JUDGE_ID" \
		'{task_id: $t, iteration_id: $i, judge_id: $j, judge_type: "standard", judge_model_id: "claude-opus-4-7"}')
	tribunal_emit_event "tribunal.judge.start" "$p"
	_validate_latest_event

	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" --arg j "$JUDGE_ID" '{
		task_id: $t,
		score: 0.82,
		passed: true,
		judge_type: "standard",
		iteration_id: $i,
		judge_id: $j,
		judge_model_id: "claude-opus-4-7",
		criteria_evaluated: ["correctness","completeness","clarity"],
		strengths_count: 3,
		weaknesses_count: 1,
		confidence: 0.85,
		feedback_summary: "looks fine"
	}')
	tribunal_emit_event "tribunal.verdict" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "meta.start + meta.complete validate (with bias_types)" {
	local p
	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" \
		'{task_id: $t, iteration_id: $i, meta_model_id: "claude-opus-4-7", verdicts_reviewed: 2}')
	tribunal_emit_event "tribunal.meta.start" "$p"
	_validate_latest_event

	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" '{
		task_id: $t,
		verdict_quality: "questionable",
		bias_detected: true,
		bias_types: ["verbosity","sycophancy"],
		override_recommendation: "re-evaluate",
		confidence: 0.7,
		iteration_id: $i,
		meta_model_id: "claude-opus-4-7"
	}')
	tribunal_emit_event "tribunal.meta.complete" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "consensus.reached validates" {
	local p
	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" --arg j "$JUDGE_ID" '{
		task_id: $t,
		iteration_id: $i,
		aggregated_score: 0.7,
		passed: true,
		aggregation_method: "weighted_mean",
		judges: [{judge_id: $j, score: 0.8},{judge_id: ($j+"X"), score: 0.6}]
	}')
	tribunal_emit_event "tribunal.consensus.reached" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "dissent.recorded validates with re-evaluate resolution" {
	local p
	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" --arg j "$JUDGE_ID" '{
		task_id: $t,
		iteration_id: $i,
		disagreement_score: 0.5,
		judges: [
			{judge_id: $j, score: 0.85, passed: true},
			{judge_id: ($j+"X"), score: 0.35, passed: false}
		],
		resolution: "re-evaluate"
	}')
	tribunal_emit_event "tribunal.dissent.recorded" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "gate.passed and gate.blocked validate" {
	local p
	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" \
		'{task_id: $t, iteration_id: $i, final_score: 0.82, iteration_number: 0, judges_consulted: 2}')
	tribunal_emit_event "tribunal.gate.passed" "$p"
	_validate_latest_event

	p=$(jq -n --arg t "$TASK_ID" --arg i "$ITER_ID" '{
		task_id: $t,
		iteration_id: $i,
		reason: "low_score",
		final_score: 0.42,
		iteration_number: 0,
		will_retry: true,
		retry_iteration_number: 1
	}')
	tribunal_emit_event "tribunal.gate.blocked" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "session.complete validates with exhausted_iterations outcome" {
	local p
	p=$(jq -n --arg t "$TASK_ID" \
		'{task_id: $t, outcome: "exhausted_iterations", final_score: 0.55, iterations_used: 3, total_duration_ms: 28000}')
	tribunal_emit_event "tribunal.session.complete" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "emission fails loudly on bogus event_type (schema rejects)" {
	run tribunal_emit_event "tribunal.no.such.event" '{"task_id":"x"}'
	[ "$status" -ne 0 ]
}

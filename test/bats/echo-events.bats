#!/usr/bin/env bats

# Validates every emitted echo.* event against @onlooker-community/schema.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export CLAUDE_SESSION_ID="bats-session-$$"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/echo-events.sh"
}

_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

SUITE_ID="01J000000000000000000000SS"
TEST_ID="01J000000000000000000000TT"

@test "echo.suite.started validates" {
	local p
	p=$(jq -n --arg s "$SUITE_ID" '{
		suite_id: $s,
		test_count: 2,
		trigger: "file_change",
		changed_file: "plugins/tribunal/agents/tribunal-judge-standard.md"
	}')
	echo_emit_event "echo.suite.started" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "echo.suite.complete validates without drift fields" {
	local p
	p=$(jq -n --arg s "$SUITE_ID" '{
		suite_id: $s,
		test_count: 1,
		improved: 0,
		degraded: 0,
		neutral: 1,
		merge_recommended: true,
		duration_ms: 3200
	}')
	echo_emit_event "echo.suite.complete" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "echo.suite.complete validates with drift fields" {
	local p
	p=$(jq -n --arg s "$SUITE_ID" '{
		suite_id: $s,
		test_count: 1,
		improved: 1,
		degraded: 0,
		neutral: 0,
		merge_recommended: true,
		duration_ms: 3200,
		baseline_score: 0.72,
		score_after: 0.85,
		drift: 0.13,
		drift_threshold: 0.05
	}')
	echo_emit_event "echo.suite.complete" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "echo.improvement.detected validates" {
	local p
	p=$(jq -n --arg s "$SUITE_ID" --arg t "$TEST_ID" '{
		suite_id: $s,
		test_id: $t,
		test_name: "tribunal-judge-standard.md",
		score_before: 0.70,
		score_after: 0.85,
		delta: 0.15,
		confidence: 0.9
	}')
	echo_emit_event "echo.improvement.detected" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "echo.regression.detected validates" {
	local p
	p=$(jq -n --arg s "$SUITE_ID" --arg t "$TEST_ID" '{
		suite_id: $s,
		test_id: $t,
		test_name: "tribunal-judge-standard.md",
		score_before: 0.85,
		score_after: 0.62,
		delta: -0.23,
		confidence: 0.88
	}')
	echo_emit_event "echo.regression.detected" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "emission fails on unknown event type" {
	run echo_emit_event "echo.no.such.event" '{"suite_id":"x"}'
	[ "$status" -ne 0 ]
}

@test "echo_emit_event returns 1 when payload is empty" {
	run echo_emit_event "echo.suite.started" ""
	[ "$status" -ne 0 ]
}

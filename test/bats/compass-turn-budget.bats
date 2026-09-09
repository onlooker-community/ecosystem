#!/usr/bin/env bats

# Covers the per-turn reset of compass's check budget.
#
# turn_check_count was written as 0 at SessionStart, incremented on every check,
# and never reset — so max_checks_per_turn: 3 meant three checks per SESSION.
# 249 of compass's 306 lifetime events were turn_budget_exhausted skips, and
# compass.check.passed had never been emitted once. See ecosystem-449.51.
#
# These tests assert the number of evaluator invocations rather than the absence
# of a block, because a gate that stops gating also blocks nothing. Each write
# targets a distinct path so the dir+stem cooldown stays out of the way.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/compass"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-events.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-sanitizer.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-transcript.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-evaluator.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-gate.sh"

	compass_config_load ""

	export SESSION_ID="test-session-budget"
	STATE_FILE="${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json"
	mkdir -p "${ONLOOKER_DIR}/compass/sessions"
	jq -n --arg sid "$SESSION_ID" \
		'{session_id:$sid,turn_check_count:0,cooldown:[],
		  circuit_breaker:{state:"closed",consecutive_failures:0,opened_at:null}}' \
		> "$STATE_FILE"

	EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	export EVAL_TALLY="${BATS_TEST_TMPDIR}/evaluations"
	: > "$EVAL_TALLY"

	LONG_CONTEXT="$(printf 'w%.0s' {1..200})"

	# Records every invocation so the tests can count them, and reports a pass
	# so nothing blocks and compass.check.passed is actually exercised.
	compass_evaluate() {
		printf 'x\n' >> "$EVAL_TALLY"
		printf '{"decision":"pass","confidence":0.95,"stddev":0.03,"primary_concern":"none","rationale":"stub","sample_count":5}'
		return 0
	}
	export -f compass_evaluate
}

_assistant_line() {
	jq -cn --arg t "$1" --arg u "uuid-a-$2" \
		'{uuid:$u,type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}' \
		>> "$TRANSCRIPT"
}

_user_line() {
	jq -cn --arg t "$1" --arg u "uuid-u-$2" \
		'{uuid:$u,type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}' \
		>> "$TRANSCRIPT"
}

_eval_count() { wc -l < "$EVAL_TALLY" | tr -d ' '; }

# Run one write, naming a distinct file each time to dodge the cooldown.
_write() {
	compass_run_gate "Write" "/tmp/budget-$1.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" "$TRANSCRIPT" >/dev/null 2>&1
}

@test "the budget still stops a fourth check inside one turn" {
	_user_line "please refactor the parser" 1
	_assistant_line "Starting on the parser now." 1

	_write a
	_write b
	_write c
	_write d

	# max_checks_per_turn is 3: the fourth write must not reach the evaluator.
	[ "$(_eval_count)" -eq 3 ]
}

@test "a new user turn restores the budget" {
	_user_line "please refactor the parser" 1
	_assistant_line "Starting on the parser now." 1

	_write a
	_write b
	_write c
	[ "$(_eval_count)" -eq 3 ] || return 1

	# A new human message is a new turn.
	_user_line "now do the same for the lexer" 2
	_assistant_line "Moving on to the lexer." 2

	_write e

	[ "$(_eval_count)" -eq 4 ]
}

@test "the assistant speaking mid-turn does not restore the budget" {
	_user_line "please refactor the parser" 1
	_assistant_line "Starting on the parser now." 1

	_write a
	_write b
	_write c

	# The assistant speaks again, but the human has not — still one turn.
	_assistant_line "Continuing with the next file." 2

	_write d

	[ "$(_eval_count)" -eq 3 ]
}

@test "an evaluated pass emits compass.check.passed" {
	_user_line "please refactor the parser" 1
	_assistant_line "Starting on the parser now." 1

	_write a

	grep '"event_type":"compass.check.passed"' "$EVENTS_LOG" \
		| jq -e '.payload.confidence == 0.95' >/dev/null
}

#!/usr/bin/env bats

# A block must not be reported as a skip (ecosystem-449.45 defect 3).
#
# When the evaluator errored, the gate emitted compass.check.skipped with reason
# "sampler_error" and THEN decided whether to allow or block. So on the
# fail-closed path the bus said compass declined to act when in fact it had
# denied the tool call — anyone reading the log concluded compass did nothing.
#
# It could not say otherwise: compass.check.failed required confidence and
# stddev as numbers, and an evaluator that failed has neither. Emitting 0/0
# would assert a measured zero rather than an absent measurement, which is a
# different and worse claim. Schema 2.21.0 makes both nullable and adds a
# reason (ecosystem-449.52 gap 2), so the denial now has a truthful event.
#
# The distinction under test is decision-shaped, not error-shaped: an evaluator
# error that ALLOWS is still a skip, because compass genuinely declined to act.
# Only the denial changes.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	load_validate_path

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

	export SESSION_ID="test-session-denial"
	STATE_FILE="${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json"

	# Long enough to clear min_context_chars (80).
	LONG_CONTEXT="$(printf 'z%.0s' {1..200})"
}

_seed_state() {
	local failures="${1:-0}"
	mkdir -p "${ONLOOKER_DIR}/compass/sessions"
	jq -n --arg sid "$SESSION_ID" --argjson f "$failures" \
		'{
			session_id: $sid,
			turn_check_count: 0,
			cooldown: [],
			circuit_breaker: {state: "closed", consecutive_failures: $f, opened_at: null}
		}' > "$STATE_FILE"
}

_stub_evaluator_error() {
	compass_evaluate() {
		printf '{"decision":"error","confidence":null,"stddev":null,"primary_concern":"none","rationale":"stub error","sample_count":0}'
		return 1
	}
	export -f compass_evaluate
}

_stub_evaluator_low_confidence() {
	compass_evaluate() {
		printf '{"decision":"fail","confidence":0.2,"stddev":0.05,"primary_concern":"scope","rationale":"unclear","sample_count":5}'
		return 0
	}
	export -f compass_evaluate
}

# Last event of a given type, or empty.
_last_event() {
	grep "\"event_type\":\"$1\"" "$ONLOOKER_EVENTS_LOG" 2>/dev/null | tail -n 1
}

@test "an evaluator error that denies emits failed, not skipped" {
	# The headline. Below the breaker threshold, so error_policy closed blocks.
	_seed_state 0
	_stub_evaluator_error

	run compass_run_gate "Write" "/tmp/denial-a.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ] || return 1

	# It really did deny — otherwise this test proves nothing about denials.
	printf '%s' "$output" | jq -e \
		'.hookSpecificOutput.permissionDecision == "deny"' >/dev/null || return 1

	[[ -n "$(_last_event compass.check.failed)" ]] || return 1
	[[ -z "$(_last_event compass.check.skipped)" ]] || return 1
}

@test "the denial reports no measurement rather than a measured zero" {
	_seed_state 0
	_stub_evaluator_error

	run compass_run_gate "Write" "/tmp/denial-b.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ] || return 1

	local ev
	ev=$(_last_event compass.check.failed)
	[[ -n "$ev" ]] || return 1
	# null, not 0. A zero here would claim the evaluator measured no confidence.
	printf '%s' "$ev" | jq -e '.payload.confidence == null' >/dev/null || return 1
	printf '%s' "$ev" | jq -e '.payload.stddev == null' >/dev/null || return 1
	printf '%s' "$ev" | jq -e '.payload.reason == "sampler_error"' >/dev/null
}

@test "an evaluator error that allows is still a skip" {
	# The breaker trips on this call and open_behavior is fail_open, so the
	# write proceeds. Compass genuinely declined to act, so skipped is correct
	# — the fix must not relabel every evaluator error as a denial.
	_seed_state 2
	_stub_evaluator_error

	run compass_run_gate "Write" "/tmp/denial-c.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ] || return 1
	# Allow is signaled by empty stdout.
	[ -z "$output" ] || return 1

	[[ -n "$(_last_event compass.check.skipped)" ]] || return 1
	[[ -z "$(_last_event compass.check.failed)" ]] || return 1
}

@test "a measured denial still carries its numbers and no reason of its own" {
	# Regression pin. Existing emitters send numbers; the schema change is
	# additive and must not disturb them.
	_seed_state 0
	_stub_evaluator_low_confidence

	run compass_run_gate "Write" "/tmp/denial-d.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ] || return 1

	local ev
	ev=$(_last_event compass.check.failed)
	[[ -n "$ev" ]] || return 1
	printf '%s' "$ev" | jq -e '.payload.confidence == 0.2' >/dev/null || return 1
	printf '%s' "$ev" | jq -e '.payload.stddev == 0.05' >/dev/null
}

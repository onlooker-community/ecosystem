#!/usr/bin/env bats

# Covers the circuit breaker's behavior on the call that opens it.
#
# The breaker exists so a failing evaluator cannot hold a session hostage:
# config.json declares open_behavior "fail_open". But opening the circuit and
# honoring it were two different code paths — the breaker opened and then fell
# through to the fail-closed block, so the call that tripped the breaker was
# itself denied. See ecosystem-449.45 defect 3 and the lockout it produced.
#
# These tests seed the state file directly rather than relying on
# compass-session-start. That is deliberate: the state-creation defect
# (ecosystem-449.45 defect 1) is a separate fix, and gating these assertions on
# it would make this file fail for the wrong reason.

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

	export SESSION_ID="test-session-breaker"
	STATE_FILE="${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json"

	# Context long enough to clear min_context_chars (80).
	LONG_CONTEXT="$(printf 'z%.0s' {1..200})"

	# The evaluator always errors — that is the condition the breaker counts.
	compass_evaluate() {
		printf '{"decision":"error","confidence":null,"stddev":null,"primary_concern":"none","rationale":"stub error","sample_count":0}'
		return 1
	}
	export -f compass_evaluate
}

# Seed session state with a given consecutive_failures count.
_seed_state() {
	local failures="$1"
	mkdir -p "${ONLOOKER_DIR}/compass/sessions"
	jq -n --arg sid "$SESSION_ID" --argjson f "$failures" \
		'{
			session_id: $sid,
			turn_check_count: 0,
			cooldown: [],
			circuit_breaker: {state: "closed", consecutive_failures: $f, opened_at: null}
		}' > "$STATE_FILE"
}

@test "the evaluator error that opens the circuit is allowed through, not blocked" {
	# consecutive_failures_to_open is 3, so this error is the third and trips it.
	_seed_state 2

	run compass_run_gate "Write" "/tmp/breaker-a.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" ""

	[ "$status" -eq 0 ]
	# Allow is signaled by an empty stdout; a block writes a deny decision.
	[ -z "$output" ]
}

@test "tripping the breaker records the circuit as open" {
	_seed_state 2

	run compass_run_gate "Write" "/tmp/breaker-b.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ] || return 1

	jq -e '.circuit_breaker.state == "open"' "$STATE_FILE" >/dev/null
}

@test "an evaluator error below the threshold still blocks under error_policy closed" {
	# Two failures short of the threshold: the breaker must not swallow the
	# fail-closed block, or this fix would disable the gate entirely.
	_seed_state 0

	run compass_run_gate "Write" "/tmp/breaker-c.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" ""
	[ "$status" -eq 0 ] || return 1

	printf '%s' "$output" | jq -e \
		'.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}

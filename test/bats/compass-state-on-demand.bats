#!/usr/bin/env bats

# Covers a gate invoked with no pre-existing session state file.
#
# compass's per-session state was only ever created by compass-session-start, so
# a session that was already running when the plugin was enabled never had one.
# _compass_state_update returned 1 rather than creating it, every caller swallowed
# that, and every _compass_state_get fell back to a default — which disabled the
# turn budget (current_count stayed 0) and the circuit breaker (failures could
# not accumulate) at the same time. That combination is what locked session
# 5dd2cc93 out of every write-class tool for the rest of its life.
# See ecosystem-449.45 defect 1, acceptance 1 and 5.
#
# scribe-capture.sh:66-73 is the create-on-demand pattern this mirrors.

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

	# Deliberately NO state file, and no sessions directory either.
	export SESSION_ID="test-session-no-state"
	STATE_FILE="${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json"

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	export EVAL_TALLY="${BATS_TEST_TMPDIR}/evaluations"
	: > "$EVAL_TALLY"

	LONG_CONTEXT="$(printf 'v%.0s' {1..200})"

	jq -cn --arg u "uuid-u-1" \
		'{uuid:$u,type:"user",message:{role:"user",content:[{type:"text",text:"please refactor the parser"}]}}' \
		>> "$TRANSCRIPT"
	jq -cn --arg u "uuid-a-1" \
		'{uuid:$u,type:"assistant",message:{role:"assistant",content:[{type:"text",text:"Starting on the parser now."}]}}' \
		>> "$TRANSCRIPT"
}

_stub_pass() {
	compass_evaluate() {
		printf 'x\n' >> "$EVAL_TALLY"
		printf '{"decision":"pass","confidence":0.95,"stddev":0.03,"primary_concern":"none","rationale":"stub","sample_count":5}'
		return 0
	}
	export -f compass_evaluate
}

# Returns 0 on purpose: the gate branches on the "error" decision, not on the
# evaluator's exit status (eval_exit is captured and never read). A non-zero
# return here would only trip bats' errexit inside the command substitution,
# which the hooks — set -uo pipefail, no -e — never do.
_stub_error() {
	compass_evaluate() {
		printf 'x\n' >> "$EVAL_TALLY"
		printf '{"decision":"error","confidence":null,"stddev":null,"primary_concern":"none","rationale":"stub error","sample_count":0}'
		return 0
	}
	export -f compass_evaluate
}

_eval_count() { wc -l < "$EVAL_TALLY" | tr -d ' '; }

_write_capture() {
	compass_run_gate "Write" "/tmp/nostate-$1.txt" "write" \
		"$LONG_CONTEXT" "$SESSION_ID" "" "$TRANSCRIPT" 2>/dev/null
}

@test "a gate run with no pre-existing state file creates it" {
	_stub_pass
	[ ! -f "$STATE_FILE" ] || return 1

	_write_capture a >/dev/null

	jq -e '.turn_check_count != null' "$STATE_FILE" >/dev/null
}

@test "with no pre-existing state the turn budget still engages" {
	_stub_pass

	_write_capture a >/dev/null
	_write_capture b >/dev/null
	_write_capture c >/dev/null
	_write_capture d >/dev/null

	# Without a state file the count never incremented, so all four were
	# evaluated and the budget was inert.
	[ "$(_eval_count)" -eq 3 ]
}

@test "with no pre-existing state a failing evaluator stops blocking" {
	_stub_error

	# consecutive_failures_to_open is 3. The third error trips the breaker and
	# fail_open takes effect, so this write is allowed rather than denied.
	_write_capture a >/dev/null
	_write_capture b >/dev/null
	run _write_capture c

	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "with no pre-existing state the breaker is recorded as open" {
	_stub_error

	_write_capture a >/dev/null
	_write_capture b >/dev/null
	_write_capture c >/dev/null

	jq -e '.circuit_breaker.state == "open"' "$STATE_FILE" >/dev/null
}

@test "the on-demand document has the same shape as the one SessionStart writes" {
	_stub_pass

	# On-demand, via the gate.
	_write_capture a >/dev/null

	# SessionStart's own copy, for a different session id.
	printf '%s' "$(jq -cn '{session_id:"seeded-by-hook",cwd:"/tmp",hook_event_name:"SessionStart"}')" \
		| "${PLUGIN_ROOT}/scripts/hooks/compass-session-start.sh" >/dev/null 2>&1 || true
	seeded="${ONLOOKER_DIR}/compass/sessions/seeded-by-hook.json"
	[ -f "$seeded" ] || return 1

	# turn_id is added by the gate's turn-boundary reset, not by either default
	# document, so compare the defaults without it.
	on_demand_paths=$(jq -S '[paths | join(".")] | map(select(. != "turn_id")) | sort' "$STATE_FILE")
	seeded_paths=$(jq -S '[paths | join(".")] | sort' "$seeded")

	[ "$on_demand_paths" = "$seeded_paths" ]
}

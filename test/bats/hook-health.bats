#!/usr/bin/env bats

# The vendored hook-health lib: clock, record shape, and fail-soft behavior.
# See docs/superpowers/specs/2026-08-29-hook-health-instrumentation-design.md

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/scripts/lib/hook-health.sh"
	HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
}

@test "the log path derives from ONLOOKER_DIR" {
	[ "$(hook_health_log_path)" = "$HEALTH_LOG" ]
}

@test "the clock returns epoch milliseconds as 13 digits" {
	local ms
	ms=$(_hook_health_now_ms)
	[[ "$ms" =~ ^[0-9]{13}$ ]] || return 1
	# Sanity: within a decade of the date this was written.
	[ "$ms" -gt 1700000000000 ]
}

@test "a success record lands with the hook name and a duration" {
	hook_health_register "unit-test-hook"
	hook_health_success
	[ -f "$HEALTH_LOG" ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.hook == "unit-test-hook"
		and .status == "success"
		and .error == null
		and (.duration_ms | type) == "number"
		and .duration_ms >= 0
	' >/dev/null
}

@test "a failure record carries the status and the error text" {
	hook_health_register "failing-hook"
	hook_health_failure "exit_code=3"
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.status == "failure" and .error == "exit_code=3"
	' >/dev/null
}

@test "context from the hook JSON lands on the record" {
	hook_health_register "ctx-hook"
	hook_health_context '{"session_id":"sess-1","tool_name":"Write","hook_event_name":"PostToolUse"}'
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.session_id == "sess-1"
		and .tool_name == "Write"
		and .hook_event == "PostToolUse"
	' >/dev/null
}

@test "absent context leaves the optional fields null, not empty strings" {
	hook_health_register "bare-hook"
	hook_health_success
	tail -n 1 "$HEALTH_LOG" | jq -e '
		.session_id == null and .tool_name == null and .hook_event == null
	' >/dev/null
}

@test "registering without writing produces no record" {
	hook_health_register "never-finished"
	[ ! -f "$HEALTH_LOG" ]
}

@test "an unwritable log directory does not fail the caller" {
	export ONLOOKER_HOOK_HEALTH_LOG="/proc/nonexistent/nope/hook-health.jsonl"
	hook_health_register "fail-soft-hook"
	run hook_health_success
	[ "$status" -eq 0 ]
}

@test "an exiting hook logs success without an explicit call" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'trapped-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "trapped-hook" and .status == "success"' >/dev/null
}

@test "a nonzero exit is recorded as a failure with the exit code" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'crashing-hook'
		exit 7
	"
	[ "$status" -eq 7 ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.status == "failure" and .error == "exit_code=7"' >/dev/null
}

# The regression this whole task exists for. Modeled on the real pattern in
# assayer-stop.sh and tribunal-stop-gate.sh.
@test "a pre-existing EXIT trap still runs after registering" {
	local victim="${BATS_TEST_TMPDIR}/prompt-file"
	touch "$victim"
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		trap 'rm -f \"${victim}\"' EXIT
		hook_health_register 'polite-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	# The prior handler ran: the temp file is gone.
	[ ! -f "$victim" ] || return 1
	# And we still got our record.
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "polite-hook"' >/dev/null
}

@test "a pre-existing trap containing single quotes survives chaining" {
	local victim="${BATS_TEST_TMPDIR}/quoted file"
	touch "$victim"
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		trap \"rm -f '${victim}'\" EXIT
		hook_health_register 'quoted-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$victim" ] || return 1
	tail -n 1 "$HEALTH_LOG" | jq -e '.hook == "quoted-hook"' >/dev/null
}

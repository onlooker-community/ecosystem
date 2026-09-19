#!/usr/bin/env bats

# ecosystem-449.66. A hook the CLI kills at its deadline must not be recorded
# as a success.
#
# WHY THE EXIT TRAP CANNOT ANSWER THIS. hook_health_register installs
# `trap '_hook_health_on_exit $?' EXIT` and branches on that exit code. When a
# signal kills the shell, bash still runs the EXIT trap, but $? inside it is the
# status of the last COMPLETED command -- typically a successful jq -- not a
# failure. Measured: 624 librarian-session-end records on the development
# machine, every one status=success, for a hook that was in fact being killed at
# the 1500ms SessionEnd deadline on nearly every session.
#
# WHY NOT A SIGNAL TRAP. Bash defers a trapped signal while it waits on a
# foreground child. Measured with a TERM trap installed and `sleep` in the
# foreground: signalled pid-only the handler ran at +9630ms; signalled
# process-group, +26ms. Untrapped, bash dies promptly in both. So installing a
# signal trap can make a hook outlive the very deadline that killed it, and it
# still cannot see SIGKILL.
#
# NOR CAN BASH_COMMAND ANSWER IT. Measured inside the EXIT trap: a hook killed
# mid-`sleep 30` reports BASH_COMMAND=[sleep 30], and a hook that fell off its
# own end reports BASH_COMMAND=[jq -n 1 > /dev/null]. Both are "a normal command,
# not an exit", so the two cases are not separable from inside the dying shell.
#
# SO THE NORMAL PATH MARKS ITSELF. Two mechanisms, covering different deaths:
#
#   hook_health_complete   the hook states it reached a termination point it
#                          chose. Without it the EXIT trap writes "terminated"
#                          instead of guessing "success" — this covers SIGTERM,
#                          where the trap still runs.
#   the start breadcrumb    register writes a record up front, so a run that
#                          left a breadcrumb and no terminal record at all was
#                          killed without any trap running — this covers
#                          SIGKILL, which no trap can see.
#
# Between them, every way a hook can die is legible, and neither asks the dying
# shell for information it provably does not have.
#
# THIS FILE COVERS THE SECOND MECHANISM ONLY. The breadcrumb is here; the
# SIGTERM half needs every hook to route its exits through hook_health_exit
# first, or flipping the trap would label all 33 of them terminated on every
# fire. That conversion and its tests are the follow-up change.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	HEALTH_LOG="${ONLOOKER_DIR}/logs/hook-health.jsonl"
	mkdir -p "${ONLOOKER_DIR}/logs"
}

# A hook that registers, completes a successful command, signals readiness, then
# blocks -- the shape of every SessionEnd hook that got killed.
_write_blocking_hook() {
	local path="$1" name="$2" marker="$3"
	cat > "$path" <<-EOF
		#!/usr/bin/env bash
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register '${name}'
		jq -n '1' >/dev/null 2>&1
		touch '${marker}'
		sleep 30
	EOF
	chmod +x "$path"
}

# Poll for the readiness marker instead of sleeping a fixed amount: the suite
# runs with -j 4 and a fixed sleep on a loaded host is a flake.
_await_marker() {
	local marker="$1" waited=0
	while [ ! -f "$marker" ]; do
		perl -e 'select(undef,undef,undef,0.02)' 2>/dev/null || sleep 1
		waited=$((waited + 1))
		[ "$waited" -lt 250 ] || return 1
	done
	return 0
}

_terminal_records() {
	local name="$1"
	[ -f "$HEALTH_LOG" ] || return 0
	jq -c --arg h "$name" 'select(.hook == $h and .status != "started")' "$HEALTH_LOG" 2>/dev/null
}

_breadcrumbs() {
	local name="$1"
	[ -f "$HEALTH_LOG" ] || return 0
	jq -c --arg h "$name" 'select(.hook == $h and .status == "started")' "$HEALTH_LOG" 2>/dev/null
}

@test "a hook killed with SIGKILL is also readable as terminated" {
	local hook="${BATS_TEST_TMPDIR}/sigkill-hook.sh"
	local marker="${BATS_TEST_TMPDIR}/ready-sigkill"
	_write_blocking_hook "$hook" 'sigkill-hook' "$marker"

	bash "$hook" &
	local pid=$!
	_await_marker "$marker" || return 1
	kill -KILL "$pid" 2>/dev/null
	wait "$pid" 2>/dev/null || true

	# No trap of any kind runs on SIGKILL, which is exactly why the sentinel is
	# written up front rather than inferred from the dying shell.
	[ "$(_breadcrumbs 'sigkill-hook' | wc -l | tr -d ' ')" -eq 1 ] || return 1
	[ "$(_terminal_records 'sigkill-hook' | wc -l | tr -d ' ')" -eq 0 ]
}

@test "a hook that completes pairs its breadcrumb with one terminal record" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'completing-hook'
		hook_health_exit 0
	"
	[ "$status" -eq 0 ] || return 1
	_terminal_records 'completing-hook' | jq -e '.status == "success"' >/dev/null || return 1
	[ "$(_breadcrumbs 'completing-hook' | wc -l | tr -d ' ')" -eq 1 ] || return 1
	[ "$(_terminal_records 'completing-hook' | wc -l | tr -d ' ')" -eq 1 ] || return 1
	# The pair must be joinable, or a consumer cannot tell which start a
	# terminal record closes when one hook fires several times in a session.
	local rid_start rid_end
	rid_start=$(_breadcrumbs 'completing-hook' | jq -r '.run_id')
	rid_end=$(_terminal_records 'completing-hook' | jq -r '.run_id')
	[ -n "$rid_start" ] || return 1
	[ "$rid_start" = "$rid_end" ]
}

@test "a breadcrumb carries the fields every existing consumer reads" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'shape-hook'
		hook_health_complete
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	# check-plugin-liveness reads .timestamp and .hook off every line, so a
	# breadcrumb missing either would make a firing hook look unsampled.
	_breadcrumbs 'shape-hook' | jq -e '
		.hook == "shape-hook"
		and .status == "started"
		and (.timestamp | type) == "string"
		and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
		and (.run_id | type) == "string"
	' >/dev/null
}

@test "every line in the log is valid JSON, breadcrumbs included" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'json-hook'
		hook_health_complete
		hook_health_context '{\"session_id\":\"sess-1\",\"tool_name\":\"Write\"}'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	# A printf-built breadcrumb is the obvious place for a quoting bug, and one
	# malformed line makes the whole log unparseable to a streaming consumer.
	run jq -e -s 'length >= 2' "$HEALTH_LOG"
	[ "$status" -eq 0 ]
}

@test "a hook name containing quotes cannot corrupt the breadcrumb" {
	run bash -c "
		source '${REPO_ROOT}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${HEALTH_LOG}'
		hook_health_register 'evil\"hook\\\\name'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	# Whatever the lib does with it -- escape or sanitize -- the log must stay
	# parseable. Asserting on parseability rather than on a specific spelling
	# keeps this test about the invariant that matters.
	run jq -e -s 'length >= 1' "$HEALTH_LOG"
	[ "$status" -eq 0 ]
}

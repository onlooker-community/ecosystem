#!/usr/bin/env bats

# Exercises the Stop hook's gating behavior. Does not run `claude -p` (the
# script bails when claude is not on PATH or when conditions don't apply), so
# these tests verify the SHORT-CIRCUIT branches: disabled, no-git, no-changes.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/tribunal-stop-gate.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	(cd "$REPO" && printf 'initial\n' > README.md && git add README.md && git commit -q -m init)

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	printf '{"role":"user","content":"hi"}\n' > "$TRANSCRIPT"
}

_make_input() {
	local cwd="$1" tp="$2" sid="${3:-test-session}"
	jq -n --arg cwd "$cwd" --arg tp "$tp" --arg sid "$sid" \
		'{cwd: $cwd, transcript_path: $tp, session_id: $sid}'
}

@test "hook exits 0 silently when stop_hook.enabled is false (default)" {
	local input
	input=$(_make_input "$REPO" "$TRANSCRIPT")
	run bash -c "printf '%s' '$input' | '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	# No verdict files written
	! find "${ONLOOKER_DIR}/tribunal" -name 'stop-*.json' 2>/dev/null | grep -q .
}

@test "hook exits 0 when enabled but no git context" {
	mkdir -p "${REPO}/.claude"
	printf '%s\n' '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}' \
		> "${REPO}/.claude/settings.json"
	# cwd outside any repo
	local non_repo="${BATS_TEST_TMPDIR}/not-a-repo"
	mkdir -p "$non_repo"
	local input
	input=$(_make_input "$non_repo" "$TRANSCRIPT")
	run bash -c "printf '%s' '$input' | '$HOOK'"
	[ "$status" -eq 0 ]
}

@test "hook skips when enabled + skip_if_no_file_changes + clean tree" {
	mkdir -p "${REPO}/.claude"
	printf '%s\n' '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":true}}}' \
		> "${REPO}/.claude/settings.json"
	local input
	input=$(_make_input "$REPO" "$TRANSCRIPT")
	run bash -c "printf '%s' '$input' | '$HOOK'"
	[ "$status" -eq 0 ]
	# No verdict files written (no changes to evaluate)
	! find "${ONLOOKER_DIR}/tribunal" -name 'stop-*.json' 2>/dev/null | grep -q .
}

@test "hook never prints to stdout (Stop must not break the contract)" {
	local input
	input=$(_make_input "$REPO" "$TRANSCRIPT")
	run bash -c "printf '%s' '$input' | '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# ecosystem-449.22. The gate invokes `claude` from inside a Stop hook
# (tribunal-stop-gate.sh:153-157), so the nested session's own Stop re-enters
# it and tribunal ends up judging its own judge. Both sibling Stop plugins
# already guard this — echo-stop-gate.sh:18 (ECHO_NESTED, whose comment names
# the `claude -p` loop outright) and assayer-stop.sh:19 (ASSAYER_NESTED) —
# and inspector uses the same idiom for PostToolUse. Tribunal had none.
#
# Not theoretical: a judge on 2026-08-30 reported scoring "a meta-evaluation
# (a judge scoring another judge's output)". The recursion is self-reported on
# the bus.
#
# Enabled deliberately, so the default-disabled branch is not what returns.
# This one mirrors the echo/assayer tests for consistency, but on its own it is
# WEAK: the fixture has a clean tree and a one-line transcript, so the hook
# exits 0 here with or without the guard. The test below is the one that
# actually discriminates.
@test "recursion guard: TRIBUNAL_NESTED=1 causes immediate exit 0" {
	mkdir -p "${REPO}/.claude"
	printf '%s\n' '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}' \
		> "${REPO}/.claude/settings.json"

	local input
	input=$(_make_input "$REPO" "$TRANSCRIPT")
	run bash -c "printf '%s' '$input' | TRIBUNAL_NESTED=1 ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ] || return 1
	! find "${ONLOOKER_DIR}/tribunal" -name 'stop-*.json' 2>/dev/null | grep -q .
}

# The guard has to sit above hook_health_register, matching echo and assayer.
# A nested invocation is not a real hook run, so measuring it would inflate the
# Stop-cadence latency numbers that wave 4 is judged against.
@test "recursion guard short-circuits before any health record is written" {
	mkdir -p "${REPO}/.claude"
	printf '%s\n' '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":false}}}' \
		> "${REPO}/.claude/settings.json"

	local health="${ONLOOKER_DIR}/logs/hook-health.jsonl"
	rm -f "$health"
	local input
	input=$(_make_input "$REPO" "$TRANSCRIPT")
	run bash -c "printf '%s' '$input' | TRIBUNAL_NESTED=1 ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ] || return 1
	[ ! -s "$health" ]
}

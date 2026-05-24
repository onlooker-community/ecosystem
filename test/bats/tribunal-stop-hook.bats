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

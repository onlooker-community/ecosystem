#!/usr/bin/env bats

# Exercises the Assayer Stop hook's gating behavior. Does not invoke claude -p
# (the hook bails before the extraction step when preconditions fail).
# Verifies: no-git, recursion guard, no-transcript, and
# stdout silence (advisory hook must never block Stop).

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/assayer-stop.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	(cd "$REPO" && printf 'initial\n' >README.md && git add README.md && git commit -q -m init)

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"All tests pass."}]}}' >"$TRANSCRIPT"
}

_make_input() {
	local cwd="${1:-$REPO}" sid="${2:-test-session}" transcript="${3:-$TRANSCRIPT}"
	jq -n --arg cwd "$cwd" --arg sid "$sid" --arg tp "$transcript" \
		'{cwd: $cwd, session_id: $sid, transcript_path: $tp}'
}

@test "exits 0 when cwd is not a git repo" {
	local non_repo="${BATS_TEST_TMPDIR}/not-a-repo"
	mkdir -p "$non_repo"
	local input
	input=$(_make_input "$non_repo")
	run bash -c "printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
}

@test "recursion guard: ASSAYER_NESTED=1 causes immediate exit 0" {
	local input
	input=$(_make_input)
	run bash -c "printf '%s' '$input' | ASSAYER_NESTED=1 ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "exits 0 when transcript is missing" {
	local input
	input=$(_make_input "$REPO" "test-session" "${BATS_TEST_TMPDIR}/nope.jsonl")
	run bash -c "printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "exits 0 when final message is empty" {
	# Transcript with no assistant text turn.
	local empty_transcript="${BATS_TEST_TMPDIR}/empty.jsonl"
	printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"hi"}]}}' >"$empty_transcript"
	local input
	input=$(_make_input "$REPO" "test-session" "$empty_transcript")
	run bash -c "printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

#!/usr/bin/env bats
#
# assayer must not pay for a claim-extraction LLM call on a message that
# asserts nothing.
#
# ecosystem-449.24. assayer-stop.sh runs `timeout 60 claude -p` on every Stop,
# gated only on "is the final message empty". Across all 449 audits ever run,
# 346 (77%) extracted zero claims — the call was pure cost. p50 for the hook is
# 10562ms and ~98.5% of that is this one call.
#
# The filter is deliberately GENEROUS: a false positive costs one Haiku call,
# a false negative silently defeats the plugin. Every literal below that is
# marked "historical" is a real claim assayer extracted in production, recovered
# from assayer.claim.* events on the bus — those must all still reach the LLM.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-extract.sh"
}

# --- messages that must still reach the extractor -------------------------

@test "a plain tests-pass claim reaches the extractor" {
	run assayer_may_contain_claims "All tests pass."
	[ "$status" -eq 0 ]
}

@test "historical: 'lint and coverage pass' reaches the extractor" {
	run assayer_may_contain_claims "lint and coverage pass"
	[ "$status" -eq 0 ]
}

@test "historical: 'Fix round 1 verified' reaches the extractor" {
	run assayer_may_contain_claims "Fix round 1 verified"
	[ "$status" -eq 0 ]
}

@test "historical: 'fully green, MERGEABLE / CLEAN' reaches the extractor" {
	run assayer_may_contain_claims 'fully green, `MERGEABLE / CLEAN`'
	[ "$status" -eq 0 ]
}

@test "historical: 'All three checks pass — coverage 20s, lint 17s' reaches the extractor" {
	run assayer_may_contain_claims "All three checks pass — coverage 20s, lint 17s, Test 5m7s"
	[ "$status" -eq 0 ]
}

@test "historical: 'ledger writing restored' reaches the extractor" {
	run assayer_may_contain_claims "ledger writing restored"
	[ "$status" -eq 0 ]
}

@test "historical: 'Commit created — 552ad07' reaches the extractor" {
	run assayer_may_contain_claims "Commit created — 552ad07 fix(config-loaders): restore plugin convenience functions"
	[ "$status" -eq 0 ]
}

@test "the build succeeded reaches the extractor" {
	run assayer_may_contain_claims "The build succeeded and typecheck is clean."
	[ "$status" -eq 0 ]
}

@test "case is ignored" {
	run assayer_may_contain_claims "ALL TESTS PASSED"
	[ "$status" -eq 0 ]
}

# --- messages that assert nothing testable --------------------------------

@test "a question asserts nothing" {
	run assayer_may_contain_claims "Which of these two approaches would you prefer for the cache layer?"
	[ "$status" -eq 1 ]
}

@test "a plan asserts nothing" {
	run assayer_may_contain_claims "Next I will read the config loader and see how it resolves the plugin root."
	[ "$status" -eq 1 ]
}

@test "a description of code asserts nothing" {
	run assayer_may_contain_claims "The hook reads transcript_path from stdin, then extracts the final assistant message."
	[ "$status" -eq 1 ]
}

@test "an empty message asserts nothing" {
	run assayer_may_contain_claims ""
	[ "$status" -eq 1 ]
}

# --- the hook must honor the filter ---------------------------------------
#
# The lib tests above pass against the unfiltered hook too — it is only these
# that prove the LLM call is actually skipped.

_hook_setup() {
	HOOK="${PLUGIN_ROOT}/scripts/hooks/assayer-stop.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	(cd "$REPO" && printf 'initial\n' >README.md && git add README.md && git commit -q -m init)

	CLAUDE_CALLED="${BATS_TEST_TMPDIR}/claude_called"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf 'x\n' >> "${CLAUDE_CALLED}"
printf '%s' '[]'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_transcript_with() {
	local text="$1" path="${BATS_TEST_TMPDIR}/t-$$.jsonl"
	jq -cn --arg t "$text" \
		'{type:"assistant", message:{content:[{type:"text", text:$t}]}}' >"$path"
	printf '%s' "$path"
}

_run_stop_hook() {
	local transcript="$1"
	jq -cn --arg cwd "$REPO" --arg sid "sess-prefilter" --arg tp "$transcript" \
		'{cwd:$cwd, session_id:$sid, transcript_path:$tp}' | "$HOOK" >/dev/null 2>&1
}

# Extraction runs in a detached child (ecosystem-449.24), so neither of these
# can read CLAUDE_CALLED the instant the hook returns — the hook returning is
# no longer evidence the audit did or did not happen. Both poll.
_wait_for_claude() {
	local waited=0
	while [[ ! -s "$CLAUDE_CALLED" && "$waited" -lt "${1:-20}" ]]; do
		sleep 1
		waited=$((waited + 1))
	done
}

@test "hook does not invoke claude when the final message asserts nothing" {
	_hook_setup
	local t
	t=$(_transcript_with "Next I will read the config loader and see how it resolves the plugin root.")
	_run_stop_hook "$t"
	# Bounded settle. Without it a broken filter still passes: the spawned child
	# would not have reached its claude call yet when the assertion runs.
	_wait_for_claude 4
	[ ! -s "$CLAUDE_CALLED" ] || { echo "claude was invoked on a message with no claims"; return 1; }
}

@test "hook still invokes claude when the final message asserts success" {
	_hook_setup
	local t
	t=$(_transcript_with "All tests pass.")
	_run_stop_hook "$t"
	_wait_for_claude
	[ -s "$CLAUDE_CALLED" ] || { echo "claude was not invoked on a real claim"; return 1; }
}

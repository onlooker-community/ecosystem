#!/usr/bin/env bats

# The Stop gate in a git worktree (ecosystem-449.37).
#
# tribunal_project_repo_root resolves a linked worktree to its parent checkout
# so both share a project key, which is right for identity and wrong for git.
# The gate then ran `git -C "$REPO_ROOT" diff` twice against that root: once to
# decide whether anything changed, and once to build the diff summary handed to
# the judge. Both read the parent checkout.
#
# The consequence is the gate quietly declining to do its job. With the
# worktree dirty and the parent clean — the normal shape of feature work — the
# dirty-tree test sees a clean tree and skips, so the work that actually
# happened is never judged. This is the same defect fixed in lineage by
# ecosystem-449.33.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/tribunal-stop-gate.sh"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-project-key.sh"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "$MAIN"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email test@example.com
	git -C "$MAIN" config user.name test
	git -C "$MAIN" remote add origin git@github.com:org/fixture.git
	(cd "$MAIN" && printf 'initial\n' > README.md && git add README.md && git commit -q -m init)

	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	printf '{"role":"user","content":"hi"}\n' > "$TRANSCRIPT"

	# Records invocation, and captures the prompt so the diff summary the judge
	# actually received can be asserted on.
	CLAUDE_MARKER="${BATS_TEST_TMPDIR}/claude-was-invoked"
	CLAUDE_PROMPT="${BATS_TEST_TMPDIR}/claude-prompt"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
printf 'invoked\n' >> "${CLAUDE_MARKER}"
cat > "${CLAUDE_PROMPT}"
printf '%s' '{"score":0.9,"passed":true,"judge_type":"standard","feedback_summary":"ok","confidence":0.9}'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	mkdir -p "${MAIN}/.claude"
	printf '%s\n' '{"tribunal":{"stop_hook":{"enabled":true,"skip_if_no_file_changes":true}}}' \
		> "${MAIN}/.claude/settings.json"
	# The worktree carries its own copy: config still loads from the parent
	# root, which ecosystem-449.37 tracks separately as a config question.
	mkdir -p "${WT}/.claude"
	cp "${MAIN}/.claude/settings.json" "${WT}/.claude/settings.json"
}

_run_from() {
	local input
	input=$(jq -n --arg cwd "$1" --arg tp "$TRANSCRIPT" --arg sid "sess-wt-1" \
		'{cwd: $cwd, transcript_path: $tp, session_id: $sid, hook_event_name: "Stop"}')
	run bash -c "printf '%s' '$input' | '$HOOK'"
}

@test "a dirty worktree is judged even when the parent checkout is clean" {
	printf 'work done in the worktree\n' >> "${WT}/README.md"
	_run_from "$WT"
	[ "$status" -eq 0 ] || return 1
	[ -f "$CLAUDE_MARKER" ]
}

@test "the judge sees the worktree's diff, not the parent's" {
	printf 'work done in the worktree\n' >> "${WT}/README.md"
	_run_from "$WT"
	[ -f "$CLAUDE_PROMPT" ] || return 1
	# The diff stat names the file that actually changed.
	run grep -c 'README.md' "$CLAUDE_PROMPT"
	[ "$output" -ge 1 ]
}

@test "a clean worktree still skips when the parent checkout is dirty" {
	# The inverse, so the fix cannot be "always run": dirtiness in the tree the
	# session is NOT in must not trigger a judge pass.
	printf 'unrelated parent-side edit\n' >> "${MAIN}/README.md"
	_run_from "$WT"
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$CLAUDE_MARKER" ]
}

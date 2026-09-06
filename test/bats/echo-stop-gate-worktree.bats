#!/usr/bin/env bats

# Echo's Stop gate in a git worktree (ecosystem-449.37).
#
# echo_project_repo_root resolves a linked worktree to its parent checkout so
# both share a project key. The gate then used that root for two different git
# jobs, and each fails in its own way:
#
#   :98-100  the changed / staged / untracked lists are read from the parent,
#            so a worktree's changes are invisible and echo is a silent no-op.
#   :184     abs_path is rebuilt as "${REPO_ROOT}/${rel_path}", so even when a
#            path does survive the filter, echo opens the PARENT's copy of it.
#
# The second is the sharper one and it is not what the bead described. Echo
# does not merely skip work in a worktree — it can score the wrong version of
# a prompt file and write that score into the baseline as if it were the
# worktree's, which then silently becomes the comparison point for the next run.
#
# Each case below isolates one of the two, so a partial fix cannot pass.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/echo-stop-gate.sh"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "${MAIN}/agents"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email test@example.com
	git -C "$MAIN" config user.name test
	git -C "$MAIN" remote add origin git@github.com:org/fixture.git
	printf '# Agent\n\nORIGINAL COMMITTED BODY\n' > "${MAIN}/agents/reviewer.md"
	git -C "$MAIN" add -A
	git -C "$MAIN" commit -qm init

	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch

	for root in "$MAIN" "$WT"; do
		mkdir -p "${root}/.claude"
		printf '%s\n' '{"echo":{"watch_paths":["agents/*.md"]}}' > "${root}/.claude/settings.json"
	done

	# Captures the evaluation prompt, which embeds the file content echo read.
	# That is what makes "which copy did it open" an assertable question.
	CLAUDE_PROMPT="${BATS_TEST_TMPDIR}/claude-prompt"
	CLAUDE_MARKER="${BATS_TEST_TMPDIR}/claude-was-invoked"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
printf 'invoked\n' >> "${CLAUDE_MARKER}"
cat >> "${CLAUDE_PROMPT}"
printf '%s' '{"score":0.8,"passed":true,"confidence":0.9,"feedback":"fine"}'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_run_from() {
	local input
	input=$(jq -n --arg cwd "$1" --arg sid "sess-echo-wt" '{cwd: $cwd, session_id: $sid}')
	run bash -c "printf '%s' '$input' | '$HOOK'"
}

@test "a watched file changed only in the worktree is evaluated" {
	# Isolates :98-100. The parent is clean, so the change is invisible to a
	# git read rooted there and echo never reaches the eval loop.
	printf '# Agent\n\nEDITED IN THE WORKTREE\n' > "${WT}/agents/reviewer.md"
	_run_from "$WT"
	[ "$status" -eq 0 ] || return 1
	[ -f "$CLAUDE_MARKER" ]
}

@test "evaluates the worktree's copy of the file, not the parent's" {
	# Isolates :184. Both trees are dirty, so the path survives the filter even
	# with the bug present — the only thing under test is which copy was read.
	printf '# Agent\n\nWORKTREE VERSION OF THE BODY\n' > "${WT}/agents/reviewer.md"
	printf '# Agent\n\nPARENT VERSION OF THE BODY\n' > "${MAIN}/agents/reviewer.md"
	_run_from "$WT"
	[ -f "$CLAUDE_PROMPT" ] || return 1
	grep -q 'WORKTREE VERSION OF THE BODY' "$CLAUDE_PROMPT" || return 1
	! grep -q 'PARENT VERSION OF THE BODY' "$CLAUDE_PROMPT"
}

@test "a change made only in the parent checkout does not trigger a worktree session" {
	# The inverse, so the fix cannot become "read both trees". Work in the
	# parent belongs to the parent's session.
	printf '# Agent\n\nEDITED IN THE PARENT\n' > "${MAIN}/agents/reviewer.md"
	_run_from "$WT"
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$CLAUDE_MARKER" ]
}

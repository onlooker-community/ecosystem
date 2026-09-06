#!/usr/bin/env bats

# Archivist's path handling in a git worktree (ecosystem-449.37, tier 2).
#
# archivist_project_repo_root resolves a linked worktree to its parent checkout
# so both share a project key. archivist-extract.sh then used that root for two
# things that are about where the files actually are:
#
#   :166  the prompt tells the model "Repository root: <root>" and asks it for
#         repository-relative paths. Told the parent's root while reading a
#         transcript full of worktree paths, the model relativizes against the
#         wrong base — so the misattribution starts before validation runs.
#   :232  archivist_validate_paths_array "$REPO_ROOT" then resolves each path
#         against that same parent root and drops whatever does not exist there.
#
# The two failure modes differ and are tested separately:
#
#   absolute worktree path  -> resolves outside the parent root, dropped.
#   relative path           -> resolved against the PARENT. It survives only if
#                              the parent happens to have that path, and the
#                              stored record then points at the parent's copy,
#                              which is a different branch's content. A file
#                              that exists only in the worktree — the normal
#                              case for feature work — is dropped.
#
# archivist_validate_repo_path's own docstring claims the opposite:
#   "Worktrees: an absolute path that lives in a checked-out worktree of the
#    same repo is considered 'in repo' — we resolve against the worktree's
#    toplevel."
# It never did that. It validates against whatever root the caller hands it.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/archivist-extract.sh"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/archivist-project-key.sh"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "${MAIN}/src"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email test@example.com
	git -C "$MAIN" config user.name test
	git -C "$MAIN" remote add origin git@github.com:org/fixture.git
	printf 'shared\n' > "${MAIN}/src/shared.ts"
	git -C "$MAIN" add -A
	git -C "$MAIN" commit -qm init

	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch

	MAIN_REAL=$(cd "$MAIN" && pwd -P)
	WT_REAL=$(cd "$WT" && pwd -P)

	# Exists ONLY in the worktree — the normal shape of feature work, and the
	# case the parent-rooted resolve silently drops.
	printf 'new work\n' > "${WT}/src/wt-only.ts"
	# Exists ONLY in the parent, so a worktree session must NOT claim it.
	printf 'other work\n' > "${MAIN}/src/main-only.ts"

	KEY=$(archivist_project_key "$WT")
	DECISIONS_DIR="${ONLOOKER_DIR}/archivist/${KEY}/decisions"

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the work"}}' > "$TRANSCRIPT"

	CLAUDE_PROMPT="${BATS_TEST_TMPDIR}/claude-prompt"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	# Returns one decision naming both a worktree-only and a parent-only path,
	# so a single run exercises the keep case and the reject case together.
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat > "${CLAUDE_PROMPT}"
printf '%s' '{"decisions":[{"summary":"a decision worth keeping","detail":"why","files":["src/wt-only.ts","src/main-only.ts"]}],"dead_ends":[],"open_questions":[]}'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_run_extract() {
	local input
	input=$(jq -n --arg cwd "$1" --arg tp "$TRANSCRIPT" --arg sid "sess-arch-wt" \
		'{cwd: $cwd, session_id: $sid, transcript_path: $tp, trigger: "auto"}')
	run bash -c "printf '%s' '$input' | '$HOOK'"
}

_files_json() {
	local f
	f=$(find "$DECISIONS_DIR" -name '*.json' -type f 2>/dev/null | head -1)
	[[ -n "$f" ]] || return 1
	jq -c '.files' "$f"
}

@test "the model is told the worktree root, not the parent's" {
	# :166. The prompt asks for repository-relative paths, so the root it names
	# is the base the model relativizes against.
	_run_extract "$WT"
	[ -f "$CLAUDE_PROMPT" ] || return 1
	grep -q "Repository root: ${WT_REAL}" "$CLAUDE_PROMPT"
}

@test "a path that exists only in the worktree is kept" {
	# :232. Resolved against the parent this file does not exist, so it was
	# dropped — silently, since a dropped path just shrinks the files array.
	_run_extract "$WT"
	run _files_json
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"src/wt-only.ts"* ]]
}

@test "a path that exists only in the parent checkout is rejected" {
	# The inverse, so the fix cannot become "accept everything". Work in the
	# parent is not this session's to claim.
	_run_extract "$WT"
	run _files_json
	[ "$status" -eq 0 ] || return 1
	[[ "$output" != *"src/main-only.ts"* ]]
}

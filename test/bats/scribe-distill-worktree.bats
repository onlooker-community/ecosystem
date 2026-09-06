#!/usr/bin/env bats

# Scribe's distillation output in a git worktree (ecosystem-449.37).
#
# scribe_project_repo_root resolves a linked worktree to its parent checkout so
# both share a project key. scribe_distill then used that root for two things
# that are not identity:
#
#   :220  mirror_dir="${project_root}/${project_dir}" — the artifact is COPIED
#         INTO the parent checkout, a tree the session was never working in.
#   :206  the same root is stamped into the document as its "Project:" line.
#
# This is the only tier-1 site in 449.37 that writes rather than reads. The
# artifact lands as an untracked file in the parent's git status, on whatever
# branch happens to be checked out there, and is absent from the branch whose
# work it documents. The document then names the wrong path, so the two halves
# corroborate each other.
#
# Extraction is stubbed by redefining scribe_extract_intent after sourcing:
# the model call is not what is under test, and stubbing it keeps these cases
# fast and deterministic.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/scribe"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/scribe-project-key.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/scribe-extract.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/scribe-distill.sh"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "$MAIN"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email test@example.com
	git -C "$MAIN" config user.name test
	git -C "$MAIN" remote add origin git@github.com:org/fixture.git
	(cd "$MAIN" && printf 'seed\n' > README.md && git add README.md && git commit -qm init)

	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch

	MAIN_REAL=$(cd "$MAIN" && pwd -P)
	WT_REAL=$(cd "$WT" && pwd -P)

	# Mirroring is off by default; these cases are about where it lands when on.
	for root in "$MAIN" "$WT"; do
		mkdir -p "${root}/.claude"
		printf '%s\n' '{"scribe":{"output":{"mirror_to_project":true,"project_dir":"docs/decisions"},"capture":{"min_turns":1}}}' \
			> "${root}/.claude/settings.json"
	done

	SESSION_ID="scribe-wt-session"
	mkdir -p "${ONLOOKER_DIR}/scribe/sessions"
	jq -n '{captured_prompt: "do the thing"}' > "${ONLOOKER_DIR}/scribe/sessions/${SESSION_ID}.json"

	TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
	printf '%s\n' \
		'{"type":"user","message":{"role":"user","content":"first"}}' \
		'{"type":"assistant","message":{"role":"assistant","content":"ok"}}' \
		'{"type":"user","message":{"role":"user","content":"second"}}' \
		'{"type":"user","message":{"role":"user","content":"third"}}' \
		> "$TRANSCRIPT"

	# Stub the Haiku pass — deterministic, and not the subject of these tests.
	scribe_extract_intent() {
		jq -nc '{problem: "a problem", decisions: ["a decision"], tradeoffs: [], outcome: "done"}'
	}

	scribe_config_load "$WT" 2>/dev/null || true
}

@test "mirrors the artifact into the worktree, not the parent checkout" {
	run scribe_distill "$SESSION_ID" "$WT" "$TRANSCRIPT"
	[ "$status" -eq 0 ] || return 1
	run bash -c "ls '${WT}/docs/decisions/' 2>/dev/null | wc -l | tr -d ' '"
	[ "$output" != "0" ]
}

@test "writes nothing into the parent checkout" {
	# The half that makes this a write bug rather than a path-cosmetics bug:
	# the parent gains an untracked file on whatever branch it has checked out.
	scribe_distill "$SESSION_ID" "$WT" "$TRANSCRIPT" >/dev/null 2>&1 || true
	[ ! -d "${MAIN}/docs/decisions" ]
}

@test "the document records the worktree it documents" {
	scribe_distill "$SESSION_ID" "$WT" "$TRANSCRIPT" >/dev/null 2>&1 || true
	local doc
	doc=$(find "${ONLOOKER_DIR}/scribe" -name '*.md' -type f 2>/dev/null | head -1)
	[ -n "$doc" ] || return 1
	grep -q "$WT_REAL" "$doc" || return 1
	! grep -q "Project:.*${MAIN_REAL}\`" "$doc"
}

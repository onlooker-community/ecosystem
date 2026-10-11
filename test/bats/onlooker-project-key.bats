#!/usr/bin/env bats
# Substrate project-key derivation (ecosystem-449.59).

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name "Test"
}

@test "derives a 12-char hex key from the origin remote" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	key=$(onlooker_project_key "$REPO")
	[[ "$key" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "the remote key is stable across two clones at different paths" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	local other="${BATS_TEST_TMPDIR}/elsewhere"
	mkdir -p "$other"
	git -C "$other" init -q
	git -C "$other" remote add origin git@github.com:org/fixture.git

	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$other")" ]
}

@test "different remotes yield different keys" {
	git -C "$REPO" remote add origin git@github.com:org/one.git
	local other="${BATS_TEST_TMPDIR}/two"
	mkdir -p "$other"
	git -C "$other" init -q
	git -C "$other" remote add origin git@github.com:org/two.git

	[ "$(onlooker_project_key "$REPO")" != "$(onlooker_project_key "$other")" ]
}

@test "falls back to the repo root when there is no remote" {
	key=$(onlooker_project_key "$REPO")
	[[ "$key" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "the remote key and the rootless key differ for the same repo" {
	local rootless; rootless=$(onlooker_project_key "$REPO")
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	[ "$rootless" != "$(onlooker_project_key "$REPO")" ]
}

@test "a worktree shares its parent's key" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	git -C "$REPO" commit -q --allow-empty -m "base"
	local wt="${BATS_TEST_TMPDIR}/wt"
	git -C "$REPO" worktree add -q -b wt-branch "$wt" >/dev/null 2>&1

	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$wt")" ]
}

@test "a worktree of a remoteless repo still shares its parent's key" {
	# The common-dir path, not the remote path. This is the branch
	# ecosystem-449.37 is about: resolve to the parent checkout for identity.
	git -C "$REPO" commit -q --allow-empty -m "base"
	local wt="${BATS_TEST_TMPDIR}/wt2"
	git -C "$REPO" worktree add -q -b wt2-branch "$wt" >/dev/null 2>&1

	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$wt")" ]
}

@test "returns empty outside a git repo" {
	local plain="${BATS_TEST_TMPDIR}/plain"
	mkdir -p "$plain"
	[ -z "$(onlooker_project_key "$plain")" ]
}

@test "worktree_root resolves a linked worktree to ITSELF, not its parent" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	git -C "$REPO" commit -q --allow-empty -m "base"
	local wt="${BATS_TEST_TMPDIR}/wt-self"
	git -C "$REPO" worktree add -q -b wt-self-branch "$wt" >/dev/null 2>&1

	# Identity collapses the two; location must not.
	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$wt")" ]
	[ "$(onlooker_worktree_root "$wt")" != "$(onlooker_worktree_root "$REPO")" ]
	[ "$(onlooker_worktree_root "$wt")" = "$(cd "$wt" && pwd -P)" ]
}

@test "worktree_root returns the toplevel for an ordinary checkout" {
	[ "$(onlooker_worktree_root "$REPO")" = "$(cd "$REPO" && pwd -P)" ]
}

@test "worktree_root returns empty outside a git repo" {
	local plain="${BATS_TEST_TMPDIR}/plain-wt"
	mkdir -p "$plain"
	[ -z "$(onlooker_worktree_root "$plain")" ]
}

@test "worktree_root returns empty for an absent or non-directory argument" {
	[ -z "$(onlooker_worktree_root "")" ]
	[ -z "$(onlooker_worktree_root "${BATS_TEST_TMPDIR}/does-not-exist")" ]
}

@test "resolve exports basis=remote for a repo with an origin" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_BASIS" = "remote" ]
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "resolve exports basis=root for a repo with no origin" {
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_BASIS" = "root" ]
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "resolve exports both empty outside a git repo" {
	local plain="${BATS_TEST_TMPDIR}/plain-resolve"
	mkdir -p "$plain"
	onlooker_project_resolve "$plain"
	[ -z "$ONLOOKER_PROJECT_KEY" ]
	[ -z "$ONLOOKER_PROJECT_BASIS" ]
}

@test "resolve clears a stale value rather than leaving the previous one" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ -n "$ONLOOKER_PROJECT_KEY" ]

	local plain="${BATS_TEST_TMPDIR}/plain-clear"
	mkdir -p "$plain"
	onlooker_project_resolve "$plain"
	[ -z "$ONLOOKER_PROJECT_KEY" ]
	[ -z "$ONLOOKER_PROJECT_BASIS" ]
}

@test "resolve exports the variables to a child process" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	run env
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "^ONLOOKER_PROJECT_BASIS=remote$"
}

@test "the key from resolve matches the key from the wrapper" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_KEY" = "$(onlooker_project_key "$REPO")" ]
}

@test "the wrapper populates the env vars as a side effect" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	unset ONLOOKER_PROJECT_KEY ONLOOKER_PROJECT_BASIS
	onlooker_project_key "$REPO" >/dev/null
	[ "$ONLOOKER_PROJECT_BASIS" = "remote" ]
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1
}

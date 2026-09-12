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

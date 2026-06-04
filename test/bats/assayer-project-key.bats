#!/usr/bin/env bats

# Exercises Assayer project-key derivation.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-project-key.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	(cd "$REPO" && printf 'x\n' >f && git add f && git commit -q -m init)
}

@test "key is 12 hex chars for a repo with a remote" {
	git -C "$REPO" remote add origin https://example.com/foo/bar.git
	run assayer_project_key "$REPO"
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9a-f]{12}$ ]]
}

@test "key is stable across calls" {
	git -C "$REPO" remote add origin https://example.com/foo/bar.git
	a=$(assayer_project_key "$REPO")
	b=$(assayer_project_key "$REPO")
	[ "$a" = "$b" ]
}

@test "remote-keyed differs from root-keyed" {
	local with_remote without_remote
	without_remote=$(assayer_project_key "$REPO")
	git -C "$REPO" remote add origin https://example.com/foo/bar.git
	with_remote=$(assayer_project_key "$REPO")
	[ "$with_remote" != "$without_remote" ]
}

@test "different remotes yield different keys" {
	git -C "$REPO" remote add origin https://example.com/foo/one.git
	local one
	one=$(assayer_project_key "$REPO")
	git -C "$REPO" remote set-url origin https://example.com/foo/two.git
	local two
	two=$(assayer_project_key "$REPO")
	[ "$one" != "$two" ]
}

@test "non-repo cwd yields empty key" {
	local non_repo="${BATS_TEST_TMPDIR}/not-a-repo"
	mkdir -p "$non_repo"
	run assayer_project_key "$non_repo"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

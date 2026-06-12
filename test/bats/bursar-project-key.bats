#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/bursar-project-key.sh"
}

_mk_repo_with_remote() {
	local dir="$1" url="$2"
	mkdir -p "$dir"
	git init -q "$dir" 2>/dev/null
	git -C "$dir" remote add origin "$url" 2>/dev/null
}

@test "key is a 12-char hex string for a repo with a remote" {
	local repo="${BATS_TEST_TMPDIR}/repo-a"
	_mk_repo_with_remote "$repo" "https://example.com/onlooker/a.git"
	run bursar_project_key "$repo"
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 12 ]
	[[ "$output" =~ ^[0-9a-f]{12}$ ]]
}

@test "same cwd yields a stable key" {
	local repo="${BATS_TEST_TMPDIR}/repo-b"
	_mk_repo_with_remote "$repo" "https://example.com/onlooker/b.git"
	local a b
	a=$(bursar_project_key "$repo")
	b=$(bursar_project_key "$repo")
	[ -n "$a" ]
	[ "$a" = "$b" ]
}

@test "different remotes yield different keys" {
	local r1="${BATS_TEST_TMPDIR}/repo-c" r2="${BATS_TEST_TMPDIR}/repo-d"
	_mk_repo_with_remote "$r1" "https://example.com/onlooker/c.git"
	_mk_repo_with_remote "$r2" "https://example.com/onlooker/d.git"
	[ "$(bursar_project_key "$r1")" != "$(bursar_project_key "$r2")" ]
}

@test "empty key for a non-git directory" {
	local plain="${BATS_TEST_TMPDIR}/not-a-repo"
	mkdir -p "$plain"
	run bursar_project_key "$plain"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

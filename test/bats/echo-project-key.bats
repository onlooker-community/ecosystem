#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/echo-project-key.sh"
}

@test "non-git directory returns empty key" {
	local d="${BATS_TEST_TMPDIR}/non-git"
	mkdir -p "$d"
	run echo_project_key "$d"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "git repo without remote falls back to repo-root hash" {
	local d="${BATS_TEST_TMPDIR}/local-only-repo"
	mkdir -p "$d"
	git -C "$d" init -q
	git -C "$d" config user.email t@example.com
	git -C "$d" config user.name "Test"

	local k1 k2
	k1=$(echo_project_key "$d")
	k2=$(echo_project_key "$d")
	[ -n "$k1" ]
	[ "${#k1}" -eq 12 ]
	[ "$k1" = "$k2" ]
}

@test "git repo with remote uses remote hash" {
	local a="${BATS_TEST_TMPDIR}/clone-a"
	local b="${BATS_TEST_TMPDIR}/clone-b"
	mkdir -p "$a" "$b"
	for d in "$a" "$b"; do
		git -C "$d" init -q
		git -C "$d" config user.email t@example.com
		git -C "$d" config user.name "Test"
		git -C "$d" remote add origin git@github.com:org/proj.git
	done

	local ka kb
	ka=$(echo_project_key "$a")
	kb=$(echo_project_key "$b")
	[ -n "$ka" ]
	[ "$ka" = "$kb" ]
}

@test "different remotes yield different keys" {
	local a="${BATS_TEST_TMPDIR}/proj-a"
	local b="${BATS_TEST_TMPDIR}/proj-b"
	mkdir -p "$a" "$b"
	for d in "$a" "$b"; do
		git -C "$d" init -q
		git -C "$d" config user.email t@example.com
		git -C "$d" config user.name "Test"
	done
	git -C "$a" remote add origin git@github.com:org/proj-a.git
	git -C "$b" remote add origin git@github.com:org/proj-b.git

	local ka kb
	ka=$(echo_project_key "$a")
	kb=$(echo_project_key "$b")
	[ -n "$ka" ]
	[ -n "$kb" ]
	[ "$ka" != "$kb" ]
}

@test "echo_test_id_for_path returns 16 hex chars" {
	local tid
	tid=$(echo_test_id_for_path "plugins/tribunal/agents/tribunal-judge-standard.md")
	[ -n "$tid" ]
	[ "${#tid}" -eq 16 ]
	[[ "$tid" =~ ^[0-9a-f]{16}$ ]]
}

@test "echo_test_id_for_path is stable across calls" {
	local a b
	a=$(echo_test_id_for_path "plugins/tribunal/agents/tribunal-judge-standard.md")
	b=$(echo_test_id_for_path "plugins/tribunal/agents/tribunal-judge-standard.md")
	[ "$a" = "$b" ]
}

@test "echo_test_id_for_path differs for different paths" {
	local a b
	a=$(echo_test_id_for_path "plugins/tribunal/agents/tribunal-judge-standard.md")
	b=$(echo_test_id_for_path "plugins/tribunal/agents/tribunal-judge-adversarial.md")
	[ "$a" != "$b" ]
}

@test "echo_project_repo_root returns empty for non-git dir" {
	local d="${BATS_TEST_TMPDIR}/not-a-repo"
	mkdir -p "$d"
	local r
	r=$(echo_project_repo_root "$d")
	[ -z "$r" ]
}

@test "echo_project_repo_root returns repo root for subdir" {
	local d="${BATS_TEST_TMPDIR}/myrepo"
	mkdir -p "${d}/sub/dir"
	git -C "$d" init -q
	git -C "$d" config user.email t@example.com
	git -C "$d" config user.name "Test"

	local r expected
	r=$(echo_project_repo_root "${d}/sub/dir")
	# Resolve symlinks — on macOS BATS_TEST_TMPDIR may differ from git's toplevel.
	expected=$(cd "$d" && pwd -P)
	[ "$r" = "$expected" ]
}

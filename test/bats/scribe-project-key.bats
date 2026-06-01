#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/scribe"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-project-key.sh"
}

@test "non-git directory returns empty key" {
  local d="${BATS_TEST_TMPDIR}/non-git"
  mkdir -p "$d"
  run scribe_project_key "$d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git repo without remote falls back to repo-root hash" {
  local d="${BATS_TEST_TMPDIR}/local-only-repo"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name "Test"

  local k1
  k1=$(scribe_project_key "$d")
  [ -n "$k1" ]
  [ "${#k1}" -eq 12 ]

  # Stability: a second call returns the same key.
  local k2
  k2=$(scribe_project_key "$d")
  [ "$k1" = "$k2" ]
}

@test "git repo with remote uses remote hash, ignores local path" {
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
  ka=$(scribe_project_key "$a")
  kb=$(scribe_project_key "$b")
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
  ka=$(scribe_project_key "$a")
  kb=$(scribe_project_key "$b")
  [ -n "$ka" ]
  [ -n "$kb" ]
  [ "$ka" != "$kb" ]
}

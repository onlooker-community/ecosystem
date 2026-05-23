#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  # Stand up a fake project repo so project-key resolution succeeds.
  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/archivist-inject-test.git

  # Compute the project key the hook will use.
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/archivist-project-key.sh"
  PROJECT_KEY=$(archivist_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  # Seed an artifact on disk for this project.
  local kind_dir="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions"
  mkdir -p "$kind_dir"
  printf '%s\n' '{
    "id": "01TESTTESTTESTTESTTESTTEST",
    "kind": "decision",
    "summary": "use git remote SHA256 as project key",
    "detail": "remote URL is stable across machines; falls back to repo path",
    "files": [],
    "created_at": "2026-05-22T10:00:00Z",
    "updated_at": "2026-05-22T10:00:00Z"
  }' > "${kind_dir}/01TESTTESTTESTTESTTESTTEST.json"

  # Project-scoped settings.json that enables archivist.
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"archivist":{"enabled":true}}' > "${PROJECT_REPO}/.claude/settings.json"
}

@test "inject hook is a no-op when archivist is disabled" {
  rm -f "${PROJECT_REPO}/.claude/settings.json"
  local input
  input=$(jq -n --arg cwd "$PROJECT_REPO" '{cwd: $cwd, source: "startup", session_id: "s"}')
  run bash -c "printf '%s' '$input' | '${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

@test "inject hook emits seeded artifact when enabled" {
  local input
  input=$(jq -n --arg cwd "$PROJECT_REPO" '{cwd: $cwd, source: "startup", session_id: "s"}')
  run bash -c "printf '%s' '$input' | '${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh'"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"use git remote SHA256 as project key"* ]]
  [[ "$ctx" == *"Archivist injected 1"* ]]
}

@test "inject hook skips when there is no git context" {
  local non_git="${BATS_TEST_TMPDIR}/no-git"
  mkdir -p "$non_git"
  local input
  input=$(jq -n --arg cwd "$non_git" '{cwd: $cwd, source: "startup", session_id: "s"}')
  run bash -c "printf '%s' '$input' | '${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

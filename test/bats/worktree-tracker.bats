#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  # shellcheck source=../../scripts/lib/onlooker-schema.sh
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
  # shellcheck source=../../scripts/lib/session-tracker.sh
  source "${REPO_ROOT}/scripts/lib/session-tracker.sh"
  # shellcheck source=../../scripts/lib/tool-history.sh
  source "${REPO_ROOT}/scripts/lib/tool-history.sh"
  # shellcheck source=../../scripts/lib/worktree-tracker.sh
  source "${REPO_ROOT}/scripts/lib/worktree-tracker.sh"
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"

  GIT_REPO="${BATS_TEST_TMPDIR}/git-repo"
  rm -rf "$GIT_REPO"
  mkdir -p "$GIT_REPO"
  git -C "$GIT_REPO" init -q
  git -C "$GIT_REPO" config user.email "test@example.com"
  git -C "$GIT_REPO" config user.name "Test User"
  echo "hello" >"$GIT_REPO/README.md"
  git -C "$GIT_REPO" add README.md
  git -C "$GIT_REPO" commit -q -m "init"
}

@test "worktree_tracker_build_record maps WorktreeCreate to tool.shell.exec" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/worktree-create.json"
  local enriched
  enriched=$(jq \
    --arg path "${GIT_REPO}/.claude/worktrees/feature-auth" \
    --arg branch "worktree-feature-auth" \
    '. + {worktree_path: $path, branch_name: $branch}' \
    "$fixture")
  export ONLOOKER_WORKTREE_DURATION_MS=42
  local record
  record=$(worktree_tracker_build_record "$enriched")
  echo "$record" | jq -e \
    '.event_type == "tool.shell.exec"
     and .payload.exit_code == 0
     and .payload.duration_ms == 42
     and (.payload.command | test("worktree:create"))
     and .payload.working_directory == "/project/repo"' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "worktree_tracker_build_record maps WorktreeRemove to tool.shell.exec" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/worktree-remove.json"
  export ONLOOKER_WORKTREE_DURATION_MS=9000
  local record
  record=$(worktree_tracker_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.event_type == "tool.shell.exec"
     and (.payload.command | test("worktree:remove"))
     and .payload.duration_ms == 9000' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "worktree-tracker WorktreeCreate prints absolute path on stdout" {
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/worktree-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/worktree-session-001"

  local input_file="${BATS_TEST_TMPDIR}/worktree-create-input.json"
  jq \
    --arg cwd "$GIT_REPO" \
    --arg sid "worktree-session-001" \
    '.cwd = $cwd | .session_id = $sid' \
    "${REPO_ROOT}/test/fixtures/hook-inputs/worktree-create.json" >"$input_file"

  local worktree_path
  worktree_path=$(cat "$input_file" | "${REPO_ROOT}/scripts/hooks/worktree-tracker.sh")
  [ -d "$worktree_path" ]
  [[ "$worktree_path" == "$(cd "$worktree_path" && pwd -P)" ]]
  [ -f "$history_file" ]
  tail -n 1 "$history_file" | jq -e '.event_type == "tool.shell.exec"' >/dev/null
}

@test "worktree-tracker WorktreeRemove records telemetry and removes worktree" {
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/worktree-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/worktree-session-001"

  local create_input_file="${BATS_TEST_TMPDIR}/worktree-create-input.json"
  local remove_input_file="${BATS_TEST_TMPDIR}/worktree-remove-input.json"
  jq \
    --arg cwd "$GIT_REPO" \
    --arg sid "worktree-session-001" \
    '.cwd = $cwd | .session_id = $sid' \
    "${REPO_ROOT}/test/fixtures/hook-inputs/worktree-create.json" >"$create_input_file"

  local worktree_path
  worktree_path=$(cat "$create_input_file" | "${REPO_ROOT}/scripts/hooks/worktree-tracker.sh")

  jq \
    --arg cwd "$GIT_REPO" \
    --arg path "$worktree_path" \
    --arg sid "worktree-session-001" \
    '.cwd = $cwd | .worktree_path = $path | .session_id = $sid' \
    "${REPO_ROOT}/test/fixtures/hook-inputs/worktree-remove.json" >"$remove_input_file"

  run bash -c "cat '${remove_input_file}' | '${REPO_ROOT}/scripts/hooks/worktree-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ ! -d "$worktree_path" ]

  tail -n 1 "$history_file" | jq -e \
    '.event_type == "tool.shell.exec"
     and (.payload.command | test("worktree:remove"))' \
    >/dev/null
}

@test "worktree-tracker mirrors worktree events to global events log" {
  local input
  input=$(jq \
    --arg cwd "$GIT_REPO" \
    '.cwd = $cwd' \
    "${REPO_ROOT}/test/fixtures/hook-inputs/worktree-create.json")
  : >"$ONLOOKER_EVENTS_LOG"

  printf '%s' "$input" | "${REPO_ROOT}/scripts/hooks/worktree-tracker.sh" >/dev/null

  tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -e \
    '.event_type == "tool.shell.exec"
     and (.payload.command | test("worktree:create"))' \
    >/dev/null
}

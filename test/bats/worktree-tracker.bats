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

@test "worktree_tracker_repo_root prints the git toplevel for a cwd inside the repo" {
  local expected
  expected=$(git -C "$GIT_REPO" rev-parse --show-toplevel)

  run worktree_tracker_repo_root "$GIT_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "worktree_tracker_repo_root returns empty for a non-repo directory" {
  local non_repo="${BATS_TEST_TMPDIR}/not-a-repo"
  mkdir -p "$non_repo"

  run worktree_tracker_repo_root "$non_repo"
  [ -z "$output" ]
}

@test "worktree_tracker_repo_root returns non-zero for empty cwd" {
  run worktree_tracker_repo_root ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "worktree_tracker_git_create creates a worktree at the expected path" {
  local name="feature-create"
  local expected="${GIT_REPO}/.claude/worktrees/${name}"

  local worktree_path
  worktree_path=$(worktree_tracker_git_create "$GIT_REPO" "$name" 2>/dev/null)

  [ "$worktree_path" = "$(cd "$expected" && pwd -P)" ]
  [ -d "$worktree_path" ]
  git -C "$GIT_REPO" worktree list --porcelain | grep -Fq "worktree $(cd "$expected" && pwd -P)"
  git -C "$GIT_REPO" show-ref --verify --quiet "refs/heads/worktree-${name}"

  worktree_tracker_git_remove "$GIT_REPO" "$worktree_path" 2>/dev/null
}

@test "worktree_tracker_git_create is idempotent for an existing worktree dir" {
  local name="feature-idempotent"

  local first second
  first=$(worktree_tracker_git_create "$GIT_REPO" "$name" 2>/dev/null)
  second=$(worktree_tracker_git_create "$GIT_REPO" "$name" 2>/dev/null)

  [ "$first" = "$second" ]
  [ -d "$second" ]

  worktree_tracker_git_remove "$GIT_REPO" "$first" 2>/dev/null
}

@test "worktree_tracker_git_create returns non-zero with missing args" {
  run worktree_tracker_git_create "$GIT_REPO" ""
  [ "$status" -ne 0 ]
}

@test "worktree_tracker_git_remove removes a registered worktree" {
  local name="feature-remove"
  local worktree_path
  worktree_path=$(worktree_tracker_git_create "$GIT_REPO" "$name" 2>/dev/null)
  [ -d "$worktree_path" ]

  worktree_tracker_git_remove "$GIT_REPO" "$worktree_path" 2>/dev/null

  [ ! -d "$worktree_path" ]
  ! git -C "$GIT_REPO" worktree list --porcelain | grep -Fq "worktree ${worktree_path}"
}

@test "worktree_tracker_record_created writes timing into the session tracker" {
  local session_id="worktree-record-001"
  local name="feature-record"
  local worktree_path="${GIT_REPO}/.claude/worktrees/${name}"
  local branch="worktree-${name}"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"

  worktree_tracker_record_created "$session_id" "$name" "$worktree_path" "$branch"

  local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  [ -f "$tracker_file" ]
  jq -e \
    --arg name "$name" \
    --arg path "$worktree_path" \
    --arg branch "$branch" \
    '.worktrees[$name].path == $path
     and .worktrees[$name].branch == $branch
     and (.worktrees[$name].start_time_ms | type == "number")' \
    "$tracker_file" >/dev/null
}

@test "worktree_tracker_record_created is a no-op with missing args" {
  local session_id="worktree-record-noop"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"

  run worktree_tracker_record_created "$session_id" "" "/some/path" "branch"
  [ "$status" -eq 0 ]
  [ ! -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}" ]
}

@test "worktree_tracker_duration_ms returns elapsed ms from a seeded start" {
  local session_id="worktree-duration-001"
  local name="feature-duration"
  local worktree_path="${GIT_REPO}/.claude/worktrees/${name}"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"

  worktree_tracker_record_created "$session_id" "$name" "$worktree_path" "worktree-${name}"

  # Rewind the recorded start_time_ms by ~2s so elapsed is a stable positive value.
  local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  local now_ms past temp
  now_ms=$(session_tracker_now_ms)
  past=$(( now_ms - 2000 ))
  temp=$(mktemp)
  jq --arg name "$name" --argjson ms "$past" \
    '.worktrees[$name].start_time_ms = $ms' "$tracker_file" >"$temp"
  mv "$temp" "$tracker_file"

  local duration
  duration=$(worktree_tracker_duration_ms "$session_id" "$worktree_path")
  [[ "$duration" =~ ^[0-9]+$ ]]
  [ "$duration" -ge 1900 ]
}

@test "worktree_tracker_duration_ms returns empty for an unknown worktree path" {
  local session_id="worktree-duration-unknown"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  turn_state_ensure_session "$session_id"

  run worktree_tracker_duration_ms "$session_id" "/never/recorded"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "worktree_tracker_clear_by_path removes the recorded entry" {
  local session_id="worktree-clear-001"
  local name="feature-clear"
  local worktree_path="${GIT_REPO}/.claude/worktrees/${name}"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"

  worktree_tracker_record_created "$session_id" "$name" "$worktree_path" "worktree-${name}"
  local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  jq -e --arg name "$name" '.worktrees | has($name)' "$tracker_file" >/dev/null

  worktree_tracker_clear_by_path "$session_id" "$worktree_path"

  jq -e --arg name "$name" '(.worktrees | has($name)) | not' "$tracker_file" >/dev/null
  run worktree_tracker_duration_ms "$session_id" "$worktree_path"
  [ -z "$output" ]
}

@test "worktree_tracker_append lands a JSON line in the session history" {
  local session_id="worktree-append-001"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${session_id}.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  local event
  event=$(jq -c -n '{event_type: "tool.shell.exec", payload: {command: "git worktree:create"}}')

  worktree_tracker_append "$session_id" "$event"

  [ -f "$history_file" ]
  tail -n 1 "$history_file" | jq -e \
    '.event_type == "tool.shell.exec"
     and (.payload.command | test("worktree:create"))' \
    >/dev/null
}

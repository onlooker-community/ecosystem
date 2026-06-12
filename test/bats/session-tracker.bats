#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
  # shellcheck source=../../scripts/lib/session-tracker.sh
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
  source "${REPO_ROOT}/scripts/lib/tool-history.sh"
  source "${REPO_ROOT}/scripts/lib/session-tracker.sh"
}

@test "session-start-tracker emits session.start for startup source" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/session-start-startup.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/session-start-001.jsonl"
  rm -f "$history_file"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/session-start-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]

  [ -f "$history_file" ]
  jq -e '.event_type == "session.start"
    and .session_id == "session-start-001"
    and .payload.working_directory == "/project/repo"' \
    "$history_file" >/dev/null

  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/session-start-001"
  jq -e '.start_source == "startup" and (.start_time_ms | type) == "number"' "$tracker" >/dev/null
}

@test "session-start-tracker does not emit session.start for compact source" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/session-start-compact.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/session-start-002.jsonl"
  rm -f "$history_file"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/session-start-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ ! -f "$history_file" ]

  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/session-start-002"
  jq -e '.start_source == "compact"' "$tracker" >/dev/null
}

@test "session-end-tracker emits session.end with duration and turn count" {
  local start_fixture="${REPO_ROOT}/test/fixtures/hook-inputs/session-start-startup.json"
  local end_fixture="${REPO_ROOT}/test/fixtures/hook-inputs/session-end-other.json"
  local session_id="session-end-001"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${session_id}.jsonl"

  rm -f "$history_file" "$tracker"

  # Seed tracker as if session had been running
  turn_state_ensure_session "$session_id"
  local past_ms
  past_ms=$(python3 -c 'import time; print(int((time.time() - 2) * 1000))' 2>/dev/null || echo 0)
  jq --argjson start_ms "$past_ms" '.start_time_ms = $start_ms | .turn_number = 3' "$tracker" >"${tracker}.tmp"
  mv "${tracker}.tmp" "$tracker"

  run bash -c "cat '${end_fixture}' | '${REPO_ROOT}/scripts/hooks/session-end-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]

  jq -e '.event_type == "session.end"
    and .session_id == "session-end-001"
    and .payload.turn_count == 3
    and .payload.end_reason == "unknown"
    and (.payload.duration_ms | type) == "number"
    and .payload.duration_ms >= 0' \
    "$history_file" >/dev/null
}

@test "session_tracker_map_end_reason maps logout to user_exit" {
  [ "$(session_tracker_map_end_reason logout)" = "user_exit" ]
}

# Seed a tracker file's start_time_ms to a deterministic point in the past.
# Usage: seed_start_ms_ago "$session_id" 5000
seed_start_ms_ago() {
  local session_id="$1"
  local ago_ms="$2"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  turn_state_ensure_session "$session_id"
  local past
  past=$(( $(session_tracker_now_ms) - ago_ms ))
  jq --argjson start_ms "$past" '.start_time_ms = $start_ms' "$tracker" >"${tracker}.tmp"
  mv "${tracker}.tmp" "$tracker"
}

@test "session_tracker_now_ms returns 13-digit epoch milliseconds" {
  local ms
  ms=$(session_tracker_now_ms)
  [[ "$ms" =~ ^[0-9]+$ ]]
  [ "${#ms}" -eq 13 ]
}

@test "session_tracker_now_ms is monotonic-ish across two calls" {
  local first second
  first=$(session_tracker_now_ms)
  second=$(session_tracker_now_ms)
  [ "$second" -ge "$first" ]
}

@test "session_tracker_git_context returns nothing for empty cwd" {
  run session_tracker_git_context ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session_tracker_git_context returns two empty lines for non-git dir" {
  local non_git="${BATS_TEST_TMPDIR}/not-a-repo"
  mkdir -p "$non_git"
  run session_tracker_git_context "$non_git"
  [ "$status" -eq 0 ]
  # Two empty fields: branch line + commit line, both empty.
  [ -z "$output" ]
  local branch commit
  branch=$(session_tracker_git_context "$non_git" | sed -n '1p')
  commit=$(session_tracker_git_context "$non_git" | sed -n '2p')
  [ -z "$branch" ]
  [ -z "$commit" ]
}

@test "session_tracker_git_context returns branch and short commit for a repo" {
  local repo="${BATS_TEST_TMPDIR}/gitrepo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b trunk
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  touch "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "initial"

  local out branch commit
  out=$(session_tracker_git_context "$repo")
  branch=$(echo "$out" | sed -n '1p')
  commit=$(echo "$out" | sed -n '2p')
  [ "$branch" = "trunk" ]
  [[ "$commit" =~ ^[0-9a-f]{7}$ ]]
}

@test "session_tracker_record_start writes start metadata to tracker" {
  local sid="rec-start-001"
  local input='{"cwd":"/p","source":"startup","model":"m","transcript_path":"/t","agent_type":"a"}'
  session_tracker_record_start "$sid" "$input"

  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  [ -f "$tracker" ]
  jq -e '.cwd == "/p"
    and .start_source == "startup"
    and .model == "m"
    and .transcript_path == "/t"
    and .agent_type == "a"
    and (.start_time_ms | type) == "number"
    and .start_time_ms > 0' "$tracker" >/dev/null
}

@test "session_tracker_record_start no-ops on empty input" {
  local sid="rec-start-empty"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  rm -f "$tracker"
  run session_tracker_record_start "$sid" ""
  [ "$status" -eq 0 ]
  [ ! -f "$tracker" ]
}

@test "session_tracker_record_start no-ops on null session_id" {
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/null"
  rm -f "$tracker"
  run session_tracker_record_start "null" '{"cwd":"/p"}'
  [ "$status" -eq 0 ]
  [ ! -f "$tracker" ]
}

@test "session_tracker_build_start_payload sets working_directory and git fields in repo" {
  local repo="${BATS_TEST_TMPDIR}/payload-repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test"
  touch "$repo/f"
  git -C "$repo" add f
  git -C "$repo" commit -q -m "init"

  local payload
  payload=$(session_tracker_build_start_payload "{\"cwd\":\"$repo\"}")
  echo "$payload" | jq -e --arg wd "$repo" '.working_directory == $wd
    and .git_branch == "main"
    and (.git_commit | test("^[0-9a-f]{7}$"))' >/dev/null
}

@test "session_tracker_build_start_payload falls back to pwd and omits git fields outside repo" {
  local non_git="${BATS_TEST_TMPDIR}/payload-nogit"
  mkdir -p "$non_git"
  local payload
  payload=$(cd "$non_git" && session_tracker_build_start_payload '{}')
  echo "$payload" | jq -e --arg wd "$non_git" '.working_directory == $wd
    and (has("git_branch") | not)
    and (has("git_commit") | not)' >/dev/null
}

@test "session_tracker_build_end_payload computes duration, turn_count, and end_reason" {
  local sid="end-payload-001"
  seed_start_ms_ago "$sid" 5000
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  jq '.turn_number = 2' "$tracker" >"${tracker}.tmp"
  mv "${tracker}.tmp" "$tracker"

  local payload
  payload=$(session_tracker_build_end_payload "$sid" '{"reason":"logout"}')
  echo "$payload" | jq -e '.duration_ms >= 5000
    and .turn_count == 2
    and .end_reason == "user_exit"' >/dev/null
}

@test "session_tracker_build_end_payload defaults when no tracker exists" {
  local sid="end-payload-missing"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  local payload
  payload=$(session_tracker_build_end_payload "$sid" '{"reason":"logout"}')
  echo "$payload" | jq -e '.duration_ms == 0 and .turn_count == 1' >/dev/null
}

@test "session_tracker_build_end_payload returns 1 for null session_id" {
  run session_tracker_build_end_payload "null" '{"reason":"logout"}'
  [ "$status" -eq 1 ]
}

@test "session_tracker_duration_ms returns elapsed ms for seeded start" {
  local sid="dur-001"
  seed_start_ms_ago "$sid" 3000
  local dur
  dur=$(session_tracker_duration_ms "$sid")
  [[ "$dur" =~ ^[0-9]+$ ]]
  [ "$dur" -ge 3000 ]
}

@test "session_tracker_duration_ms returns 0 for null session_id" {
  [ "$(session_tracker_duration_ms null)" = "0" ]
}

@test "session_tracker_duration_ms returns 0 for missing tracker" {
  local sid="dur-missing"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  [ "$(session_tracker_duration_ms "$sid")" = "0" ]
}

@test "session_tracker_duration_ms returns 0 for invalid start_time_ms" {
  local sid="dur-invalid"
  turn_state_ensure_session "$sid"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  jq '.start_time_ms = "not-a-number"' "$tracker" >"${tracker}.tmp"
  mv "${tracker}.tmp" "$tracker"
  [ "$(session_tracker_duration_ms "$sid")" = "0" ]
}

@test "session_tracker_update_duration persists session_duration_ms" {
  local sid="upd-001"
  seed_start_ms_ago "$sid" 2000
  session_tracker_update_duration "$sid"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  jq -e '.session_duration_ms >= 2000' "$tracker" >/dev/null
}

@test "session_tracker_update_duration returns 0 for null session_id" {
  run session_tracker_update_duration "null"
  [ "$status" -eq 0 ]
}

@test "session_tracker_update_duration creates tracker with zero duration for new sid" {
  local sid="upd-new"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  rm -f "$tracker"
  session_tracker_update_duration "$sid"
  [ -f "$tracker" ]
  jq -e '.session_duration_ms == 0' "$tracker" >/dev/null
}

@test "session_tracker_build_duration_context renders turn and humanized elapsed" {
  local sid="ctx-001"
  seed_start_ms_ago "$sid" 154000
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  jq '.turn_number = 3' "$tracker" >"${tracker}.tmp"
  mv "${tracker}.tmp" "$tracker"

  local out
  out=$(session_tracker_build_duration_context "$sid")
  [[ "$out" == *"turn 3"* ]]
  [[ "$out" == *"2m 34s"* ]]
}

@test "session_tracker_build_duration_context defaults for missing tracker" {
  local sid="ctx-missing"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  local out
  out=$(session_tracker_build_duration_context "$sid")
  [[ "$out" == *"turn 1"* ]]
  [[ "$out" == *"0s"* ]]
}

@test "session_tracker_emit appends to both session history and events log" {
  export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
  local sid="emit-001"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${sid}.jsonl"
  rm -f "$history_file"
  : >"$ONLOOKER_EVENTS_LOG"

  run session_tracker_emit "$sid" "session.start" '{"working_directory":"/tmp"}'
  [ "$status" -eq 0 ]

  [ -f "$history_file" ]
  jq -e '.event_type == "session.start" and .session_id == "emit-001"' "$history_file" >/dev/null
  grep -q '"event_type":"session.start"' "$ONLOOKER_EVENTS_LOG" \
    || jq -e 'select(.event_type == "session.start" and .session_id == "emit-001")' "$ONLOOKER_EVENTS_LOG" >/dev/null
}

@test "session_tracker_emit no-ops on empty session_id" {
  export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
  : >"$ONLOOKER_EVENTS_LOG"
  run session_tracker_emit "" "session.start" '{"working_directory":"/tmp"}'
  [ "$status" -eq 0 ]
  [ ! -s "$ONLOOKER_EVENTS_LOG" ]
}

@test "session_tracker_emit no-ops on empty event_type" {
  export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
  local sid="emit-noevent"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${sid}.jsonl"
  rm -f "$history_file"
  : >"$ONLOOKER_EVENTS_LOG"
  run session_tracker_emit "$sid" "" '{"working_directory":"/tmp"}'
  [ "$status" -eq 0 ]
  [ ! -f "$history_file" ]
  [ ! -s "$ONLOOKER_EVENTS_LOG" ]
}

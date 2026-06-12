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
  # shellcheck source=../../scripts/lib/task-tracker.sh
  source "${REPO_ROOT}/scripts/lib/task-tracker.sh"
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
}

@test "task_tracker_build_record maps TaskCreated to task.start" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/task-created.json"
  local record
  record=$(task_tracker_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.schema_version == "1.0"
     and .event_type == "task.start"
     and .payload.task_summary == "Implement user authentication"
     and .session_id == "task-session-001"' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "task_tracker_build_record maps TaskCompleted to task.complete" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/task-completed.json"
  export ONLOOKER_TASK_DURATION_MS=5000
  local record
  record=$(task_tracker_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.event_type == "task.complete"
     and .payload.success == true
     and .payload.duration_ms == 5000
     and .payload.output_summary == "Add login and signup endpoints"' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "task-tracker records task.start on TaskCreated" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/task-created.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/task-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/task-session-001"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/task-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -f "$history_file" ]
  tail -n 1 "$history_file" | jq -e '.event_type == "task.start"' >/dev/null
  tail -n 1 "$history_file" | onlooker_validate_event

  jq -e '.tasks["task-001"].start_time_ms | type == "number"' \
    "${ONLOOKER_SESSION_TRACKERS_DIR}/task-session-001" >/dev/null
}

@test "task-tracker records task.complete with duration on TaskCompleted" {
  local created_fixture="${REPO_ROOT}/test/fixtures/hook-inputs/task-created.json"
  local completed_fixture="${REPO_ROOT}/test/fixtures/hook-inputs/task-completed.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/task-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/task-session-001"

  cat "$created_fixture" | "${REPO_ROOT}/scripts/hooks/task-tracker.sh" >/dev/null 2>&1

  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/task-session-001"
  local past_ms
  past_ms=$(python3 -c 'import time; print(int((time.time() - 2) * 1000))' 2>/dev/null || echo 0)
  jq --argjson start_ms "$past_ms" '.tasks["task-001"].start_time_ms = $start_ms' "$tracker" >"${tracker}.tmp"
  mv "${tracker}.tmp" "$tracker"

  run bash -c "cat '${completed_fixture}' | '${REPO_ROOT}/scripts/hooks/task-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]

  tail -n 1 "$history_file" | jq -e \
    '.event_type == "task.complete"
     and .payload.success == true
     and (.payload.duration_ms | type) == "number"
     and .payload.duration_ms >= 0' \
    >/dev/null
  tail -n 1 "$history_file" | onlooker_validate_event

  run jq -e '.tasks["task-001"]' "$tracker"
  [ "$status" -ne 0 ]
}

@test "task-tracker mirrors task events to global events log" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/task-created.json"
  : >"$ONLOOKER_EVENTS_LOG"

  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/task-tracker.sh" >/dev/null 2>&1

  tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -e '.event_type == "task.start"' >/dev/null
  tail -n 1 "$ONLOOKER_EVENTS_LOG" | onlooker_validate_event
}

@test "task_tracker_record_created writes start_time_ms as a number" {
  local sid="rec-session-001"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"

  run task_tracker_record_created "$sid" "task-rec-001"
  [ "$status" -eq 0 ]
  [ -f "$tracker" ]
  jq -e '.tasks["task-rec-001"].start_time_ms | type == "number"' "$tracker" >/dev/null
}

@test "task_tracker_record_created no-ops on empty session_id" {
  run task_tracker_record_created "" "task-rec-002"
  [ "$status" -eq 0 ]
  [ ! -e "${ONLOOKER_SESSION_TRACKERS_DIR}/" ] || \
    [ -z "$(find "${ONLOOKER_SESSION_TRACKERS_DIR}" -type f 2>/dev/null)" ]
}

@test "task_tracker_record_created no-ops on null session_id" {
  run task_tracker_record_created "null" "task-rec-003"
  [ "$status" -eq 0 ]
  [ ! -f "${ONLOOKER_SESSION_TRACKERS_DIR}/null" ]
}

@test "task_tracker_record_created no-ops on empty task_id" {
  local sid="rec-session-empty-task"
  run task_tracker_record_created "$sid" ""
  [ "$status" -eq 0 ]
  [ ! -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}" ]
}

@test "task_tracker_duration_ms returns elapsed ms for a seeded task" {
  local sid="dur-session-001"
  turn_state_ensure_session "$sid"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"

  local past
  past=$(( $(session_tracker_now_ms) - 2000 ))
  jq --argjson ms "$past" '.tasks["task-dur-001"] = {start_time_ms: $ms}' \
    "$tracker" >"${tracker}.tmp"
  mv "${tracker}.tmp" "$tracker"

  local elapsed
  elapsed=$(task_tracker_duration_ms "$sid" "task-dur-001")
  [ -n "$elapsed" ]
  echo "$elapsed" | grep -Eq '^[0-9]+$'
  [ "$elapsed" -ge 1900 ]
}

@test "task_tracker_duration_ms is empty for an unknown task_id" {
  local sid="dur-session-unknown"
  turn_state_ensure_session "$sid"

  local out
  run task_tracker_duration_ms "$sid" "task-does-not-exist"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "task_tracker_clear removes the task timing entry" {
  local sid="clear-session-001"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"

  task_tracker_record_created "$sid" "task-clear-001"
  jq -e '.tasks["task-clear-001"]' "$tracker" >/dev/null

  run task_tracker_clear "$sid" "task-clear-001"
  [ "$status" -eq 0 ]

  run jq -e '.tasks["task-clear-001"]' "$tracker"
  [ "$status" -ne 0 ]
}

@test "task_tracker_clear no-ops when tracker file is missing" {
  local sid="clear-session-missing"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  rm -f "$tracker"

  run task_tracker_clear "$sid" "task-nope"
  [ "$status" -eq 0 ]
  [ ! -f "$tracker" ]
}

@test "task_tracker_append delegates to tool_history_append" {
  local sid="append-session-001"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${sid}.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  local event
  event=$(jq -c -n --arg sid "$sid" \
    '{schema_version: "1.0",
      plugin: "ecosystem",
      session_id: $sid,
      event_type: "task.start",
      payload: {task_summary: "append test"}}')

  run task_tracker_append "$sid" "$event"
  [ "$status" -eq 0 ]
  [ -f "$history_file" ]
  tail -n 1 "$history_file" | jq -e '.event_type == "task.start"' >/dev/null
  tail -n 1 "$history_file" | jq -e '.session_id == "append-session-001"' >/dev/null
}

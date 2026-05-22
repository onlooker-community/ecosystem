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

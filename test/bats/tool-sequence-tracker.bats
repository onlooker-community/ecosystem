#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
}

@test "tool-sequence-tracker approves and increments turn_tool_seq" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/non-agent-tool.json"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/test-session-001"
  rm -f "$tracker"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/tool-sequence-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "approve"' >/dev/null

  jq -e '.turn_number == 1 and .turn_tool_seq == 1' "$tracker" >/dev/null
}

@test "tool-sequence-tracker increments on successive tool calls" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/non-agent-tool.json"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/test-session-001"
  rm -f "$tracker"

  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/tool-sequence-tracker.sh" >/dev/null 2>&1
  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/tool-sequence-tracker.sh" >/dev/null 2>&1

  jq -e '.turn_tool_seq == 2' "$tracker" >/dev/null
}

@test "turn_state_ensure_session creates tracker with defaults" {
  local session_id="ensure-session"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  rm -f "$tracker"

  turn_state_ensure_session "$session_id"
  [ "$?" -eq 0 ]
  jq -e '.turn_number == 1 and .turn_tool_seq == 0' "$tracker" >/dev/null
}

@test "turn_state_next_tool increments existing tracker" {
  local session_id="next-tool-session"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  rm -f "$tracker"

  turn_state_ensure_session "$session_id"
  turn_state_next_tool "$session_id"
  turn_state_next_tool "$session_id"

  jq -e '.turn_tool_seq == 2' "$tracker" >/dev/null
}

#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
  source "${REPO_ROOT}/scripts/lib/tool-history.sh"
  source "${REPO_ROOT}/scripts/lib/session-tracker.sh"
  source "${REPO_ROOT}/scripts/lib/turn-tracker.sh"
}

@test "turn-tracker emits session.prompt on first user prompt at turn 1" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit.json"
  local session_id="prompt-session-001"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${session_id}.jsonl"
  rm -f "$tracker" "$history_file"

  turn_state_ensure_session "$session_id"
  jq '.start_time_ms = 1000' "$tracker" >"${tracker}.tmp" && mv "${tracker}.tmp" "$tracker"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/turn-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]

  jq -e '.turn_number == 1 and .user_prompts_seen == true' "$tracker" >/dev/null
  jq -e '.event_type == "session.prompt"
    and .payload.turn_number == 1
    and (.payload.input_summary | contains("UserPromptSubmit"))' \
    "$history_file" >/dev/null
}

@test "turn-tracker increments turn on second user prompt" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit-turn2.json"
  local session_id="prompt-session-002"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  rm -f "$tracker"

  turn_state_ensure_session "$session_id"
  jq '.user_prompts_seen = true | .turn_number = 1' "$tracker" >"${tracker}.tmp" && mv "${tracker}.tmp" "$tracker"

  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/turn-tracker.sh" >/dev/null 2>&1

  jq -e '.turn_number == 2 and .turn_tool_seq == 0' "$tracker" >/dev/null
}

@test "session-duration-tracker outputs additionalContext with elapsed time" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit.json"
  local session_id="prompt-session-001"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  rm -f "$tracker"

  turn_state_ensure_session "$session_id"
  local past_ms
  past_ms=$(python3 -c 'import time; print(int((time.time() - 65) * 1000))' 2>/dev/null || echo 0)
  jq --argjson start_ms "$past_ms" \
    '.start_time_ms = $start_ms | .turn_number = 2' \
    "$tracker" >"${tracker}.tmp" && mv "${tracker}.tmp" "$tracker"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/session-duration-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e \
    '.hookSpecificOutput.hookEventName == "UserPromptSubmit"
    and (.hookSpecificOutput.additionalContext | contains("turn 2"))
    and (.hookSpecificOutput.additionalContext | contains("elapsed"))' >/dev/null

  jq -e '(.session_duration_ms | type) == "number" and .session_duration_ms >= 60000' "$tracker" >/dev/null
}

@test "session_tracker_format_duration renders minutes and seconds" {
  [ "$(session_tracker_format_duration 65000)" = "1m 5s" ]
}

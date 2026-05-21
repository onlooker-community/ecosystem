#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  : >"$ONLOOKER_EVENTS_LOG"
  export ONLOOKER_HOOK_TYPE="PreToolUse"
  export ONLOOKER_TOOL_NAME="Agent"
  export ONLOOKER_TURN_NUMBER="5"
  export ONLOOKER_TURN_TOOL_SEQ="1"
}

@test "onlooker-emit writes enriched envelope to events log" {
  local payload='{"session_id":"emit-direct-session","agent_id":"99"}'
  "${REPO_ROOT}/scripts/lib/onlooker-emit.sh" "tool.agent.spawn" "$payload"
  [ "$?" -eq 0 ]
  tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -e \
    '.event_type == "tool.agent.spawn"
     and .session_id == "emit-direct-session"
     and .plugin == "onlooker"
     and .hook_type == "PreToolUse"
     and .tool_name == "Agent"
     and .turn == 5
     and .tool_call_seq == 1
     and .payload.agent_id == "99"' \
    >/dev/null
}

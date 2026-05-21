#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  # shellcheck source=../../scripts/lib/onlooker-schema.sh
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
  export _HOOK_SESSION_ID="emit-direct-session"
  export ONLOOKER_PLUGIN_NAME="onlooker"
  : >"$ONLOOKER_EVENTS_LOG"
}

@test "onlooker-emit writes canonical tool.agent.spawn to events log" {
  local payload='{"subagent_id":"agent-99","agent_name":"explore","task_summary":"search"}'
  "${REPO_ROOT}/scripts/lib/onlooker-emit.sh" "tool.agent.spawn" "$payload"
  [ "$?" -eq 0 ]
  tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -e \
    '.schema_version == "1.0"
     and .event_type == "tool.agent.spawn"
     and .session_id == "emit-direct-session"
     and .plugin == "onlooker"
     and .payload.subagent_id == "agent-99"' \
    >/dev/null
  tail -n 1 "$ONLOOKER_EVENTS_LOG" | onlooker_validate_event
}

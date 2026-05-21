#!/usr/bin/env bash
# Shared helpers for Onlooker hook scripts.
# Requires validate-path.sh to be sourced first (provides safe_emit).

# Emit canonical tool.agent.spawn telemetry event.
# Usage: onlooker_emit_tool_agent_spawn SESSION_ID SUBAGENT_TYPE DESCRIPTION MODEL RUN_IN_BACKGROUND ISOLATION
onlooker_emit_tool_agent_spawn() {
  local session_id="$1"
  local subagent_type="$2"
  local description="$3"
  local model="$4"
  local run_in_background="$5"
  local isolation="$6"

  local payload
  payload=$(jq -n \
    --arg sid "$session_id" \
    --arg type "$subagent_type" \
    --arg desc "$description" \
    --arg model "$model" \
    --argjson bg "$run_in_background" \
    --arg isolation "$isolation" \
    '{
      session_id: $sid,
      subagent_type: $type,
      description: $desc,
      model: $model,
      run_in_background: $bg,
      isolation: $isolation
    }')

  safe_emit "tool.agent.spawn" "$payload"
}

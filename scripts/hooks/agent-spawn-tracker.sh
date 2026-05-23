#!/usr/bin/env bash
# Onlooker Agent Spawn Tracker Script
# Invoked by the PreToolUse hook (via command) when an Agent tool is used.
#
# Usage:
#   echo "$INPUT" | agent-spawn-tracker.sh
#
# Input:
#   {
#     "session_id": "123",
#     "tool_name": "Agent",
#     "tool_input": {
#       "agent_id": "456"
#     }
#   }

set -uo pipefail # No -e: we must never exit non-zero and block the hook

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/../..}/scripts/common.sh"

hook_register "agent-spawn-tracker" "Agent Spawn Tracker" "Tracks when an agent is spawned"

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "Unknown"')

hook_set_context "$INPUT" "PreToolUse"

json_response() {
	jq -n --arg decision "$1" --arg reason "$2" '{ "decision": $decision, "reason": $reason }'
}

# Only process Agent tool calls
if [[ "$TOOL_NAME" != "Agent" ]]; then
	json_response "approve" "Not an Agent tool call"
	hook_success
	exit 0
fi

# Extract agent parameters
SUBAGENT_TYPE=$(jq -r '.tool_input.subagent_type // "general-purpose"' <<<"$INPUT")
DESCRIPTION=$(jq -r '.tool_input.description // ""' <<<"$INPUT")
RUN_IN_BACKGROUND=$(jq -r '.tool_input.run_in_background // false' <<<"$INPUT")
ISOLATION=$(jq -r '.tool_input.isolation // "worktree"' <<<"$INPUT")
MODEL=$(jq -r '.tool_input.model // "sonnet"' <<<"$INPUT")
MAX_TURNS=$(jq -r '.tool_input.max_turns // 10' <<<"$INPUT")
TOOLS=$(jq -r '.tool_input.tools // []' <<<"$INPUT")
DISALLOWED_TOOLS=$(jq -r '.tool_input.disallowed_tools // []' <<<"$INPUT")
SKILLS=$(jq -r '.tool_input.skills // []' <<<"$INPUT")
MEMORY=$(jq -r '.tool_input.memory // false' <<<"$INPUT")
BACKGROUND=$(jq -r '.tool_input.background // false' <<<"$INPUT")
ISOLATION=$(jq -r '.tool_input.isolation // "worktree"' <<<"$INPUT")
MODEL=$(jq -r '.tool_input.model // "sonnet"' <<<"$INPUT")
MAX_TURNS=$(jq -r '.tool_input.max_turns // 10' <<<"$INPUT")
TOOLS=$(jq -r '.tool_input.tools // []' <<<"$INPUT")
DISALLOWED_TOOLS=$(jq -r '.tool_input.disallowed_tools // []' <<<"$INPUT")
SKILLS=$(jq -r '.tool_input.skills // []' <<<"$INPUT")
MEMORY=$(jq -r '.tool_input.memory // false' <<<"$INPUT")
BACKGROUND=$(jq -r '.tool_input.background // false' <<<"$INPUT")

# Track agent spawns in telemetry log
STATE_FILE="$ONLOOKER_DIR/agent-spawn-trackers.json"
LOCKFILE="$STATE_FILE.lock"

# Acquire exclusive access via the portable lock helper (mkdir-based mutex,
# works on macOS without util-linux).
lock_acquire "$LOCKFILE" 5 || {
	json_response "deny" "Failed to acquire lock"
	hook_failure
	exit 0
}

# Load or initialize state
if [[ -f "$STATE_FILE" ]]; then
	STATE=$(jq '.' "$STATE_FILE" 2>/dev/null) || STATE='{}'
else
	STATE='{}'
fi

# Get Session ID for tracking
SESSION_ID=$(jq -r '.session_id // "unknown"' <<<"$INPUT") || SESSION_ID="unknown"

# Export turn state so envelope and payload include parent lineage
turn_state_export "$SESSION_ID"

# Initialize session tracking if needed
STATE=$(jq --arg sid "$SESSION_ID" '
	if .sessions[$sid] == null then
		.sessions[$sid] = {
			spawns: 0,
			background_spawns: 0,
			types: {},
			first_spawn: now | strftime("%Y-%m-%dT%H:%M:%SZ"),
			last_spawn: null
		}
	else .
	end
' <<<"$STATE")

# Save state
echo "$STATE" > "$STATE_FILE" 2>/dev/null || true

# Release lock
lock_release "$LOCKFILE"

# Get current session stats
SPAWN_COUNT=$(jq -r --arg sid "$SESSION_ID" '.sessions[$sid].spawns' <<<"$STATE")
BG_SPAWN_COUNT=$(jq -r --arg sid "$SESSION_ID" '.sessions[$sid].background_spawns' <<<"$STATE")

## Warn on potential issues
WARNING=""

# High spawn count warning
if (( SPAWN_COUNT > 10 )); then
  WARNING="Note: $SPAWN_COUNT agents spawned this session. Consider if tasks could be consolidated."
fi

# Many background agents warning (cumulative this session)
if (( BG_SPAWN_COUNT > 5 )); then
  WARNING="${WARNING:+$WARNING\n}Note: $BG_SPAWN_COUNT background agents spawned this session. Consider tracking completion."
fi

# Worktree isolation note (informational)
if [[ "$ISOLATION" == "worktree" ]]; then
  WARNING="${WARNING:+$WARNING\n}Info: Agent using worktree isolation - changes will be in separate branch."
fi

if [[ -n "$WARNING" ]]; then
  json_response "approve" "$WARNING"
else
  json_response "approve" "Agent spawn tracked (#$SPAWN_COUNT: $SUBAGENT_TYPE)"
fi

PAYLOAD=$(jq -n \
  --arg type "$SUBAGENT_TYPE" \
  --arg desc "$DESCRIPTION" \
  --argjson bg "$RUN_IN_BACKGROUND" \
  --arg isolation "$ISOLATION" \
  --arg model "$MODEL" \
  --argjson spawn_num "$SPAWN_COUNT" \
  --arg parent_sid "$SESSION_ID" \
  --arg parent_turn "${ONLOOKER_TURN_NUMBER:-}" \
  '{
    subagent_type: $type,
    description: $desc,
    run_in_background: $bg,
    isolation: $isolation,
    model: $model,
    session_spawn_number: $spawn_num,
    parent_session_id: $parent_sid
  }
  + (if $parent_turn != "" then {parent_turn: ($parent_turn | tonumber)} else {} end)
  ')

# Canonical event: tool.agent.spawn (@onlooker-community/schema)
onlooker_emit_tool_agent_spawn "$SESSION_ID" "$SUBAGENT_TYPE" "$DESCRIPTION" "$MODEL" "$RUN_IN_BACKGROUND" "$ISOLATION" 2>/dev/null && hook_success || hook_failure "Failed to emit tool.agent.spawn event"

exit 0
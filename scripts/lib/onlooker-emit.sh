#!/usr/bin/env bash
# onlooker-emit.sh - Shared event emission utility for Onlooker hooks.
#
# Usage:
#   echo "$INPUT" | onlooker-emit.sh "event-type" "payload-json"
#
# Input:
#   {
#     "session_id": "123",
#     "tool_name": "Agent",
#     "tool_input": {
#       "agent_id": "456"
#     }
#   }
#
# Envelope fields (set via env vars by validate-path.sh hook_set_context):
#   ONLOOKER_HOOK_TYPE     — Claude Code hook type (PreToolUse, PostToolUse, Stop, etc.)
#   ONLOOKER_TOOL_NAME     — Tool name for Pre/PostToolUse hooks
#   ONLOOKER_TURN_NUMBER   — Turn sequence within session (set by turn-tracker.sh)
#   ONLOOKER_TURN_TOOL_SEQ — Tool call sequence within current turn
set -euo pipefail

# Source shared validation utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate-path.sh
source "$SCRIPT_DIR/validate-path.sh"

EVENT_TYPE="$1"
PAYLOAD_JSON="$2"

# Session ID: prefer env var set by hook_set_context() (stdin is typically
# consumed by the calling hook script before safe_emit() is called).
# Fall back to extracting from payload JSON if env var is empty.
SESSION_ID="${_HOOK_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
  SESSION_ID=$(echo "$PAYLOAD_JSON" | jq -r '.session_id // "unknown"' 2>/dev/null) || SESSION_ID="unknown"
fi
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
PLUGIN="${ONLOOKER_PLUGIN_NAME:-unknown}"

# Turn-level envelope fields (empty string = omit from JSON)
HOOK_TYPE="${ONLOOKER_HOOK_TYPE:-}"
TOOL_NAME="${ONLOOKER_TOOL_NAME:-}"
TURN="${ONLOOKER_TURN_NUMBER:-}"
TOOL_SEQ="${ONLOOKER_TURN_TOOL_SEQ:-}"

OUT="$ONLOOKER_EVENTS_LOG"
ensure_dir_exists "$(dirname "$OUT")"

jq -cn \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg plugin "$PLUGIN" \
  --arg type "$EVENT_TYPE" \
  --arg hook_type "$HOOK_TYPE" \
  --arg tool_name "$TOOL_NAME" \
  --arg turn "$TURN" \
  --arg tool_seq "$TOOL_SEQ" \
  --argjson payload "$PAYLOAD_JSON" \
  '{
    timestamp: $ts,
    session_id: $sid,
    plugin: $plugin,
    event_type: $type,
    payload: $payload
  }
  + (if $hook_type != "" then {hook_type: $hook_type} else {} end)
  + (if $tool_name != "" then {tool_name: $tool_name} else {} end)
  + (if $turn != "" then {turn: ($turn | tonumber)} else {} end)
  + (if $tool_seq != "" then {tool_call_seq: ($tool_seq | tonumber)} else {} end)
  ' >> "$OUT" 2>/dev/null || true

hook_success
exit 0
#!/usr/bin/env bash
# Onlooker Tool Sequence Tracker
# Invoked by PreToolUse (matcher: *) before every tool call.
#
# Increments turn_tool_seq in the session tracker so downstream hooks and
# event emission can stamp tool_call_seq on the current turn.
#
# Usage:
#   echo "$INPUT" | tool-sequence-tracker.sh

set -uo pipefail # No -e: never block the tool call

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"

hook_register "tool-sequence-tracker" "Tool Sequence Tracker" "Increments tool call sequence within the current turn"

INPUT=$(cat)
hook_set_context "$INPUT" "PreToolUse"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

json_response() {
  jq -n --arg decision "$1" --arg reason "$2" '{ "decision": $decision, "reason": $reason }'
}

turn_state_next_tool "$SESSION_ID"
turn_state_export "$SESSION_ID"

json_response "approve" "Tool sequence #${ONLOOKER_TURN_TOOL_SEQ:-0} (turn ${ONLOOKER_TURN_NUMBER:-1})"
hook_success
exit 0

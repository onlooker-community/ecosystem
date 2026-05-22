#!/usr/bin/env bash
# Onlooker Turn Tracker
# Invoked by UserPromptSubmit when the user submits a prompt.
#
# Advances per-session turn_number (first prompt stays at turn 1) and emits
# canonical session.prompt for telemetry.
#
# Usage:
#   echo "$INPUT" | turn-tracker.sh

set -uo pipefail # No -e: never block prompt submission

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"
source "$SCRIPT_DIR/../lib/session-tracker.sh"
source "$SCRIPT_DIR/../lib/turn-tracker.sh"

hook_register "turn-tracker" "Turn Tracker" "Tracks conversation turns and emits session.prompt"

INPUT=$(cat)
hook_set_context "$INPUT" "UserPromptSubmit"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')

turn_tracker_on_user_prompt "$SESSION_ID" || hook_failure "Failed to advance turn state"
turn_state_export "$SESSION_ID"

PAYLOAD=$(turn_tracker_build_prompt_payload "$SESSION_ID" "$PROMPT")
if [[ -n "$PAYLOAD" ]]; then
	session_tracker_emit "$SESSION_ID" "session.prompt" "$PAYLOAD" \
		|| hook_failure "Failed to emit session.prompt"
fi

hook_success
exit 0

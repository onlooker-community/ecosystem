#!/usr/bin/env bash
# Onlooker Tool History Tracker
# Invoked by PostToolUse and PostToolUseFailure (matcher: *) after each tool call.
#
# Appends canonical OnlookerEvent records to:
#   ~/.onlooker/session-history/<session_id>.jsonl  (per-session analysis)
#   ~/.onlooker/logs/onlooker-events.jsonl           (global telemetry)
#
# Usage:
#   echo "$INPUT" | tool-history-tracker.sh

set -uo pipefail # No -e: never block or alter tool results

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"

hook_register "tool-history-tracker" "Tool History Tracker" "Records canonical tool events to session JSONL"

INPUT=$(cat)

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "PostToolUse"')
hook_set_context "$INPUT" "$HOOK_EVENT"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
turn_state_export "$SESSION_ID"

RECORD=$(tool_history_build_record "$INPUT")
if [[ -n "$RECORD" ]]; then
	tool_history_append "$SESSION_ID" "$RECORD" || hook_failure "Failed to append session history"
	onlooker_append_event "$RECORD" || hook_failure "Failed to append global event log"
fi

hook_success
exit 0

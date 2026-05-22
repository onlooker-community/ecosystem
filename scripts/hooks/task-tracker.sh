#!/usr/bin/env bash
# Onlooker Task Tracker
# Invoked by TaskCreated and TaskCompleted when agent team tasks are created or completed.
#
# Records canonical task.start and task.complete events to:
#   ~/.onlooker/session-history/<session_id>.jsonl
#   ~/.onlooker/logs/onlooker-events.jsonl
#
# Usage:
#   echo "$INPUT" | task-tracker.sh

set -uo pipefail # No -e: never block task create/complete

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/session-tracker.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"
source "$SCRIPT_DIR/../lib/task-tracker.sh"

hook_register "task-tracker" "Task Tracker" "Records task.start and task.complete canonical events"

INPUT=$(cat)

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
hook_set_context "$INPUT" "$HOOK_EVENT"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TASK_ID=$(echo "$INPUT" | jq -r '.task_id // ""')

turn_state_export "$SESSION_ID"

case "$HOOK_EVENT" in
TaskCreated)
	task_tracker_record_created "$SESSION_ID" "$TASK_ID" \
		|| hook_failure "Failed to record task start time"
	;;
TaskCompleted)
	DURATION_MS=$(task_tracker_duration_ms "$SESSION_ID" "$TASK_ID")
	if [[ -n "$DURATION_MS" ]]; then
		export ONLOOKER_TASK_DURATION_MS="$DURATION_MS"
	fi
	;;
*)
	hook_success
	exit 0
	;;
esac

RECORD=$(task_tracker_build_record "$INPUT")
if [[ -n "$RECORD" ]]; then
	task_tracker_append "$SESSION_ID" "$RECORD" || hook_failure "Failed to append session history"
	onlooker_append_event "$RECORD" || hook_failure "Failed to append global event log"
fi

if [[ "$HOOK_EVENT" == "TaskCompleted" && -n "$TASK_ID" ]]; then
	task_tracker_clear "$SESSION_ID" "$TASK_ID"
fi

hook_success
exit 0

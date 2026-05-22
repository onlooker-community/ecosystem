#!/usr/bin/env bash
# Onlooker Session Duration Tracker
# Invoked by UserPromptSubmit when the user submits a prompt.
#
# Updates session_duration_ms on the tracker and injects turn + elapsed time
# into Claude's context via UserPromptSubmit additionalContext.
#
# Usage:
#   echo "$INPUT" | session-duration-tracker.sh

set -uo pipefail # No -e: never block prompt submission

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/session-tracker.sh"

hook_register "session-duration-tracker" "Session Duration Tracker" "Surfaces session elapsed time on each user prompt"

INPUT=$(cat)
hook_set_context "$INPUT" "UserPromptSubmit"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

session_tracker_update_duration "$SESSION_ID" || hook_failure "Failed to update session duration"

CONTEXT=$(session_tracker_build_duration_context "$SESSION_ID")
if [[ -n "$CONTEXT" ]]; then
	jq -n \
		--arg ctx "$CONTEXT" \
		'{
			hookSpecificOutput: {
				hookEventName: "UserPromptSubmit",
				additionalContext: $ctx
			}
		}'
fi

hook_success
exit 0

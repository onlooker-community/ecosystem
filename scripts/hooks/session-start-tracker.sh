#!/usr/bin/env bash
# Onlooker Session Start Tracker
# Invoked by SessionStart (matcher: *) when a session starts or resumes.
#
# Initializes per-session tracker state and emits session.start for
# startup, resume, and clear sources (compact is metadata-only).
#
# Usage:
#   echo "$INPUT" | session-start-tracker.sh

set -uo pipefail # No -e: never block session startup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"
source "$SCRIPT_DIR/../lib/session-tracker.sh"

hook_register "session-start-tracker" "Session Start Tracker" "Records session.start and initializes session tracker"

INPUT=$(cat)
hook_set_context "$INPUT" "SessionStart"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

session_tracker_record_start "$SESSION_ID" "$INPUT" || hook_failure "Failed to record session start metadata"

# Compaction reuses the session; do not emit another session.start.
if [[ "$SOURCE" != "compact" ]]; then
	PAYLOAD=$(session_tracker_build_start_payload "$INPUT")
	if [[ -n "$PAYLOAD" ]]; then
		session_tracker_emit "$SESSION_ID" "session.start" "$PAYLOAD" \
			|| hook_failure "Failed to emit session.start"
	fi
fi

hook_success
exit 0

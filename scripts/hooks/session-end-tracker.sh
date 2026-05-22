#!/usr/bin/env bash
# Onlooker Session End Tracker
# Invoked by SessionEnd (matcher: *) when a session ends.
#
# Emits session.end with duration and turn count, then cleans up hook bus dirs.
# Default SessionEnd budget is 1.5s — keep this hook fast.
#
# Usage:
#   echo "$INPUT" | session-end-tracker.sh

set -uo pipefail # No -e: never block session termination

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"
source "$SCRIPT_DIR/../lib/session-tracker.sh"

hook_register "session-end-tracker" "Session End Tracker" "Records session.end and cleans up session resources"

INPUT=$(cat)
hook_set_context "$INPUT" "SessionEnd"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

PAYLOAD=$(session_tracker_build_end_payload "$SESSION_ID" "$INPUT")
if [[ -n "$PAYLOAD" ]]; then
	session_tracker_emit "$SESSION_ID" "session.end" "$PAYLOAD" \
		|| hook_failure "Failed to emit session.end"
fi

hook_bus_cleanup

hook_success
exit 0

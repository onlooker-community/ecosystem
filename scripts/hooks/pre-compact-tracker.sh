#!/usr/bin/env bash
# Onlooker Pre-Compact Tracker
# Invoked by PreCompact (matchers: manual, auto) before context compaction.
#
# Records pending compact state and estimated tokens_before from the transcript.
# Always approves compaction unless extended later with policy checks.
#
# Usage:
#   echo "$INPUT" | pre-compact-tracker.sh

set -uo pipefail # No -e: never block compaction unless policy added

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"
source "$SCRIPT_DIR/../lib/session-tracker.sh"
source "$SCRIPT_DIR/../lib/compact-tracker.sh"

hook_register "pre-compact-tracker" "Pre-Compact Tracker" "Records compaction intent before context is compacted"

INPUT=$(cat)
hook_set_context "$INPUT" "PreCompact"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "auto"')

compact_tracker_record_pre "$SESSION_ID" "$INPUT" || hook_failure "Failed to record pre-compact state"

json_response() {
	jq -n --arg decision "$1" --arg reason "$2" '{ "decision": $decision, "reason": $reason }'
}

json_response "approve" "Compaction tracked (${TRIGGER})"
hook_success
exit 0

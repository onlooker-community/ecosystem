#!/usr/bin/env bash
# Onlooker Context Compact Tracker
# Invoked by PostCompact (matchers: manual, auto) after context compaction.
#
# Persists compact summaries, emits canonical session.compact, and finalizes
# compact tracker state.
#
# Usage:
#   echo "$INPUT" | context-compact-tracker.sh

set -uo pipefail # No -e: never alter compaction result

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"
source "$SCRIPT_DIR/../lib/session-tracker.sh"
source "$SCRIPT_DIR/../lib/compact-tracker.sh"

hook_register "context-compact-tracker" "Context Compact Tracker" "Records compaction results and emits session.compact"

INPUT=$(cat)
hook_set_context "$INPUT" "PostCompact"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')

compact_tracker_append_summary "$SESSION_ID" "$INPUT" || hook_failure "Failed to append compact summary"
compact_tracker_record_post "$SESSION_ID" "$INPUT" || hook_failure "Failed to finalize compact state"

PAYLOAD=$(compact_tracker_build_compact_payload "$SESSION_ID" "$INPUT")
if [[ -n "$PAYLOAD" ]]; then
	session_tracker_emit "$SESSION_ID" "session.compact" "$PAYLOAD" \
		|| hook_failure "Failed to emit session.compact"
fi

hook_success
exit 0

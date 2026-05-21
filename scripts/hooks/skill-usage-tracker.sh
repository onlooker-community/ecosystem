#!/usr/bin/env bash
# Onlooker Skill Usage Tracker
# Invoked by UserPromptExpansion (slash commands) and PreToolUse (matcher: Skill).
#
# Records canonical skill.invoked events to:
#   ~/.onlooker/session-history/<session_id>.jsonl
#   ~/.onlooker/logs/onlooker-events.jsonl
#
# Usage:
#   echo "$INPUT" | skill-usage-tracker.sh

set -uo pipefail # No -e: never block skill invocation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"
source "$SCRIPT_DIR/../lib/skill-usage.sh"

hook_register "skill-usage-tracker" "Skill Usage Tracker" "Records skill.invoked canonical events"

INPUT=$(cat)

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "UserPromptExpansion"')
hook_set_context "$INPUT" "$HOOK_EVENT"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
turn_state_export "$SESSION_ID"

# PreToolUse Skill hooks must approve the tool call
if [[ "$HOOK_EVENT" == "PreToolUse" ]]; then
	TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
	if [[ "$TOOL_NAME" != "Skill" ]]; then
		hook_success
		exit 0
	fi
fi

RECORD=$(skill_usage_build_record "$INPUT")
if [[ -n "$RECORD" ]]; then
	skill_usage_append "$SESSION_ID" "$RECORD" || hook_failure "Failed to append session history"
	onlooker_append_event "$RECORD" || hook_failure "Failed to append global event log"
fi

if [[ "$HOOK_EVENT" == "PreToolUse" ]]; then
	SKILL_NAME=$(echo "$RECORD" | jq -r '.payload.skill_name // empty' 2>/dev/null)
	jq -n --arg msg "Skill tracked${SKILL_NAME:+: $SKILL_NAME}" '{ "decision": "approve", "reason": $msg }'
fi

hook_success
exit 0

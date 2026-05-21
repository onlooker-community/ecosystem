#!/usr/bin/env bash
# Skill usage helpers — canonical session JSONL via @onlooker-community/schema.
#
# Source after validate-path.sh and onlooker-schema.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/validate-path.sh"
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/onlooker-schema.sh"
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/skill-usage.sh"
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/tool-history.sh"

# Build a canonical skill.invoked event from hook stdin (empty when unmapped).
# Usage: record=$(skill_usage_build_record "$INPUT")
skill_usage_build_record() {
	local input_json="${1:-}"
	onlooker_event_from_hook "$input_json"
}

# Append a canonical skill event to session history (reuses tool-history flock).
# Usage: skill_usage_append "$SESSION_ID" "$event_json"
skill_usage_append() {
	tool_history_append "$1" "$2"
}

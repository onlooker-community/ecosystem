#!/usr/bin/env bash
# Onlooker Prompt Rule Injector
# Invoked by UserPromptSubmit. Loads declarative prompt rules from
#   ~/.onlooker/prompt-rules.json (global)
#   <cwd>/.claude/prompt-rules.json (project, overrides global by id)
# and injects guidance for rules whose POSIX-ERE pattern matches the prompt.
# Each rule fires at most once per session per rule_id.
#
# Emits canonical-ish events to ~/.onlooker/logs/onlooker-events.jsonl:
#   prompt_rule.matched — every match (including subsequent matches in-session)
#   prompt_rule.applied — only when guidance is actually injected
#
# Usage:
#   echo "$INPUT" | prompt-rule-injector.sh

set -uo pipefail # No -e: never block prompt submission

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/validate-path.sh
source "$SCRIPT_DIR/../lib/validate-path.sh"
# shellcheck source=../lib/prompt-rules.sh
source "$SCRIPT_DIR/../lib/prompt-rules.sh"

hook_register "prompt-rule-injector" "Prompt Rule Injector" "Injects declarative guidance when regex rules match prompts"

INPUT=$(cat)
hook_set_context "$INPUT" "UserPromptSubmit"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[[ -z "$CWD" ]] && CWD="$PWD"

turn_state_export "$SESSION_ID"

CONFIG_FILE="${CLAUDE_PLUGIN_ROOT:-}/config.json"
PER_TURN_MAX_CHARS=1200
ENABLED=true
if [[ -f "$CONFIG_FILE" ]]; then
  # `// true` would coerce an explicit `false` to true; check the field explicitly.
  ENABLED=$(jq -r 'if (.prompt_rules.enabled == false) then "false" else "true" end' "$CONFIG_FILE" 2>/dev/null) || ENABLED=true
  PER_TURN_MAX_CHARS=$(jq -r '.prompt_rules.per_turn_max_chars // 1200' "$CONFIG_FILE" 2>/dev/null) || PER_TURN_MAX_CHARS=1200
fi

if [[ "$ENABLED" != "true" ]]; then
  hook_success
  exit 0
fi

RULES=$(prompt_rules_load_merged "$CWD")
RULE_COUNT=$(echo "$RULES" | jq 'length' 2>/dev/null || echo 0)
if [[ "$RULE_COUNT" -eq 0 ]]; then
  hook_success
  exit 0
fi

FIRED=$(prompt_rules_load_fired "$SESSION_ID")
COMBINED_GUIDANCE=""
COMBINED_LEN=0

while IFS= read -r rule; do
  [[ -z "$rule" ]] && continue
  RULE_ID=$(echo "$rule" | jq -r '.id // empty')
  PATTERN=$(echo "$rule" | jq -r '.pattern // empty')
  GUIDANCE=$(echo "$rule" | jq -r '.guidance // empty')
  MAX_CHARS=$(echo "$rule" | jq -r '.max_chars // 400')
  FIRE_ONCE=$(echo "$rule" | jq -r '.fire_once_per_session // true')

  [[ -z "$RULE_ID" || -z "$PATTERN" || -z "$GUIDANCE" ]] && continue

  if ! prompt_rules_pattern_matches "$PROMPT" "$PATTERN"; then
    continue
  fi

  prompt_rules_emit "$SESSION_ID" "prompt_rule.matched" \
    "$(jq -cn --arg id "$RULE_ID" '{rule_id: $id}')" || true

  ALREADY_FIRED=$(echo "$FIRED" | jq --arg id "$RULE_ID" 'index($id) != null' 2>/dev/null)
  if [[ "$FIRE_ONCE" == "true" && "$ALREADY_FIRED" == "true" ]]; then
    continue
  fi

  if (( ${#GUIDANCE} > MAX_CHARS )); then
    GUIDANCE="${GUIDANCE:0:$MAX_CHARS}"
  fi

  ADD_LEN=${#GUIDANCE}
  # +2 accounts for the blank-line separator between guidance entries.
  if (( COMBINED_LEN + ADD_LEN + 2 > PER_TURN_MAX_CHARS )); then
    continue
  fi

  if [[ -n "$COMBINED_GUIDANCE" ]]; then
    COMBINED_GUIDANCE="$COMBINED_GUIDANCE"$'\n\n'"$GUIDANCE"
    COMBINED_LEN=$(( COMBINED_LEN + ADD_LEN + 2 ))
  else
    COMBINED_GUIDANCE="$GUIDANCE"
    COMBINED_LEN=$ADD_LEN
  fi

  prompt_rules_mark_fired "$SESSION_ID" "$RULE_ID" || hook_failure "Failed to mark rule fired: $RULE_ID"
  FIRED=$(prompt_rules_load_fired "$SESSION_ID")

  prompt_rules_emit "$SESSION_ID" "prompt_rule.applied" \
    "$(jq -cn --arg id "$RULE_ID" --argjson chars "$ADD_LEN" \
      '{rule_id: $id, guidance_chars: $chars}')" || true
done < <(echo "$RULES" | jq -c '.[]')

if [[ -n "$COMBINED_GUIDANCE" ]]; then
  jq -n --arg ctx "$COMBINED_GUIDANCE" \
    '{
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $ctx
      }
    }'
fi

hook_success
exit 0

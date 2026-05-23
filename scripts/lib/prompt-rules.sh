#!/usr/bin/env bash
# Prompt-rule library — declarative regex-triggered guidance injection.
#
# Source after validate-path.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/validate-path.sh"
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/prompt-rules.sh"
#
# Rule schema (JSON file at ~/.onlooker/prompt-rules.json or <cwd>/.claude/prompt-rules.json):
#   {
#     "rules": [
#       {
#         "id": "rule-no-verify-warning",
#         "pattern": "--no-verify",
#         "guidance": "Skipping hooks usually masks the real issue.",
#         "fire_once_per_session": true,
#         "max_chars": 400,
#         "enabled": true,
#         "tags": ["safety"]
#       }
#     ]
#   }
#
# Patterns are POSIX ERE (bash [[ =~ ]] semantics). `\b` is unsupported;
# use `(^|[^a-zA-Z0-9_])foo([^a-zA-Z0-9_]|$)` for word-boundary behavior.

export ONLOOKER_PROMPT_RULES_DIR="${ONLOOKER_PROMPT_RULES_DIR:-$ONLOOKER_DIR/prompt-rules}"
export ONLOOKER_PROMPT_RULES_SESSIONS_DIR="$ONLOOKER_PROMPT_RULES_DIR/sessions"

# Path to the global rules file.
# Usage: path=$(prompt_rules_global_path)
prompt_rules_global_path() {
  printf '%s\n' "$ONLOOKER_DIR/prompt-rules.json"
}

# Path to the project-scoped rules file for a given cwd.
# Usage: path=$(prompt_rules_project_path "$cwd")
prompt_rules_project_path() {
  local cwd="${1:-$PWD}"
  printf '%s\n' "$cwd/.claude/prompt-rules.json"
}

# Path to the fired-marker file for a session.
# Usage: path=$(prompt_rules_fired_path "$session_id")
prompt_rules_fired_path() {
  local session_id="${1:-unknown}"
  printf '%s\n' "$ONLOOKER_PROMPT_RULES_SESSIONS_DIR/$session_id.json"
}

# Print the merged rules JSON array. Project entries override global by id.
# Disabled rules (enabled: false) are filtered out.
# Usage: rules=$(prompt_rules_load_merged "$cwd")
prompt_rules_load_merged() {
  local cwd="${1:-$PWD}"
  local global_path project_path
  global_path=$(prompt_rules_global_path)
  project_path=$(prompt_rules_project_path "$cwd")

  local global_json='[]'
  local project_json='[]'
  if [[ -f "$global_path" ]]; then
    global_json=$(jq -c '.rules // []' "$global_path" 2>/dev/null) || global_json='[]'
  fi
  if [[ -f "$project_path" ]]; then
    project_json=$(jq -c '.rules // []' "$project_path" 2>/dev/null) || project_json='[]'
  fi

  jq -n \
    --argjson g "$global_json" \
    --argjson p "$project_json" \
    '
    def to_map(arr): (arr | map({(.id): .}) | add) // {};
    (to_map($g) + to_map($p))
    | to_entries
    | map(.value)
    | map(select(.enabled != false))
    '
}

# Print the fired-id JSON array for a session.
# Usage: fired=$(prompt_rules_load_fired "$session_id")
prompt_rules_load_fired() {
  local session_id="${1:-unknown}"
  local path
  path=$(prompt_rules_fired_path "$session_id")
  if [[ -f "$path" ]]; then
    jq -c '.fired_ids // []' "$path" 2>/dev/null || echo '[]'
  else
    echo '[]'
  fi
}

# Mark a rule id as fired for a session. Idempotent.
# Usage: prompt_rules_mark_fired "$session_id" "$rule_id"
prompt_rules_mark_fired() {
  local session_id="${1:-unknown}"
  local rule_id="${2:-}"
  [[ -z "$rule_id" ]] && return 1
  local path
  path=$(prompt_rules_fired_path "$session_id")
  ensure_dir_exists "$(dirname "$path")" || return 1

  local current='[]'
  if [[ -f "$path" ]]; then
    current=$(jq -c '.fired_ids // []' "$path" 2>/dev/null) || current='[]'
  fi
  local next
  next=$(jq -cn --argjson cur "$current" --arg id "$rule_id" \
    '{fired_ids: ($cur + [$id] | unique)}')
  printf '%s\n' "$next" > "$path"
}

# Test whether a POSIX ERE pattern matches the given prompt.
# Returns 0 on match, 1 otherwise. Empty pattern never matches.
# Usage: prompt_rules_pattern_matches "$prompt" "$pattern" && echo "hit"
prompt_rules_pattern_matches() {
  local prompt="$1"
  local pattern="$2"
  [[ -z "$pattern" ]] && return 1
  [[ "$prompt" =~ $pattern ]]
}

# Append a prompt-rule event to the global events log.
# These event types (prompt_rule.matched, prompt_rule.applied) are not yet
# in @onlooker-community/schema; once added, swap to onlooker_append_event.
# Usage: prompt_rules_emit "$session_id" "prompt_rule.matched" "$payload_json"
prompt_rules_emit() {
  local session_id="${1:-unknown}"
  local event_type="${2:-}"
  local payload_json="${3:-{\}}"
  [[ -z "$event_type" ]] && return 1
  ensure_file_exists "$ONLOOKER_EVENTS_LOG" || return 1

  local timestamp plugin
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  plugin="${ONLOOKER_PLUGIN_NAME:-onlooker}"

  jq -cn \
    --arg ts "$timestamp" \
    --arg sid "$session_id" \
    --arg plugin "$plugin" \
    --arg type "$event_type" \
    --argjson payload "$payload_json" \
    --arg turn "${ONLOOKER_TURN_NUMBER:-}" \
    '{timestamp: $ts, session_id: $sid, plugin: $plugin, event_type: $type, payload: $payload}
     + (if $turn != "" then {turn: ($turn | tonumber)} else {} end)
    ' >> "$ONLOOKER_EVENTS_LOG"
}

# Print a human-readable table of merged rules with their fired status.
# Usage: prompt_rules_list_table "$session_id" "$cwd"
prompt_rules_list_table() {
  local session_id="${1:-unknown}"
  local cwd="${2:-$PWD}"

  local rules fired global_path project_path
  rules=$(prompt_rules_load_merged "$cwd")
  fired=$(prompt_rules_load_fired "$session_id")
  global_path=$(prompt_rules_global_path)
  project_path=$(prompt_rules_project_path "$cwd")

  local rule_count
  rule_count=$(echo "$rules" | jq 'length' 2>/dev/null || echo 0)

  printf 'Prompt rules (session: %s)\n' "$session_id"
  printf '  global file:  %s%s\n' "$global_path" \
    "$([[ -f "$global_path" ]] && printf '' || printf ' (missing)')"
  printf '  project file: %s%s\n' "$project_path" \
    "$([[ -f "$project_path" ]] && printf '' || printf ' (missing)')"
  printf '  active rules: %s\n' "$rule_count"
  printf '\n'

  if [[ "$rule_count" -eq 0 ]]; then
    printf '  (no rules)\n'
    return 0
  fi

  echo "$rules" | jq -r --argjson fired "$fired" '
    .[]
    | . as $rule
    | "  - id: \(.id)\n"
      + "    pattern: \(.pattern)\n"
      + "    fired: \(if ($fired | any(. == $rule.id)) then "yes" else "no" end)\n"
      + "    guidance: \(.guidance)\n"
  '
}

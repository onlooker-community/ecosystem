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

# The canonical emitter is a sibling file, so resolve it from this script's own
# location rather than from a caller-supplied $CLAUDE_PLUGIN_ROOT. Sourcing this
# lib from a scope that never set that variable then still yields a working
# emit path instead of a silent no-op.
_PROMPT_RULES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PROMPT_RULES_EVENT_JS="$_PROMPT_RULES_LIB_DIR/onlooker-event.mjs"

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
    # Coerce non-array inputs to []; drop entries without a string id so a
    # single malformed rule cannot poison `map({(.id): .})` (which errors when
    # `.id` is null or non-string).
    def to_array(x): if (x | type) == "array" then x else [] end;
    def sanitize(arr): to_array(arr) | map(select(type == "object" and (.id | type) == "string" and .id != ""));
    def to_map(arr): (sanitize(arr) | map({(.id): .}) | add) // {};
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
# Read-modify-write is wrapped in a portable file lock so concurrent
# UserPromptSubmit hooks (or other writers) can't drop updates or corrupt
# the marker file — same pattern as tool-history.sh.
# Usage: prompt_rules_mark_fired "$session_id" "$rule_id"
prompt_rules_mark_fired() {
  local session_id="${1:-unknown}"
  local rule_id="${2:-}"
  [[ -z "$rule_id" ]] && return 1
  local path
  path=$(prompt_rules_fired_path "$session_id")
  ensure_dir_exists "$(dirname "$path")" || return 1

  local lockfile="${path}.lock"
  lock_acquire "$lockfile" 5 || return 1

  local current='[]'
  if [[ -f "$path" ]]; then
    current=$(jq -c '.fired_ids // []' "$path" 2>/dev/null) || current='[]'
  fi
  local next rc=0
  next=$(jq -cn --argjson cur "$current" --arg id "$rule_id" \
    '{fired_ids: ($cur + [$id] | unique)}')
  printf '%s\n' "$next" > "$path" || rc=$?
  lock_release "$lockfile"
  return "$rc"
}

# Test whether a POSIX ERE pattern matches the given prompt.
# Returns 0 on match, 1 otherwise (including empty or invalid pattern).
# Invalid ERE patterns from user-edited rule files would otherwise leak a
# "syntax error in regular expression" message to stderr and return status 2;
# we treat that as a non-match so the hook stays quiet on bad input.
# Usage: prompt_rules_pattern_matches "$prompt" "$pattern" && echo "hit"
prompt_rules_pattern_matches() {
  local prompt="$1"
  local pattern="$2"
  [[ -z "$pattern" ]] && return 1
  { [[ "$prompt" =~ $pattern ]]; } 2>/dev/null
  local rc=$?
  # Bash returns 2 for a malformed regex; collapse to "no match".
  if (( rc == 0 )); then
    return 0
  fi
  return 1
}

# Append a prompt-rule event to the global events log.
#
# Routes through onlooker-event.mjs like every other emit path in the repo, so
# the envelope is built once, in one place, and validated against
# @onlooker-community/schema wherever that package resolves (dev, CI, tests).
#
# This used to hand-build a five-field envelope with jq. That envelope was
# never valid: it omitted every required id/schema_version/runtime/machine_id/
# sequence field, and it added a `turn` field the envelope forbids outright
# (event.v1.json is additionalProperties:false and has no `turn`). The canonical
# emitter carries a turn as `turn_number` INSIDE the payload, and neither
# prompt_rule payload schema has that property, so a turn number has nowhere
# valid to go on these two event types and is no longer recorded.
#
# Fails closed: if the emitter is missing or rejects the payload, nothing is
# written. A dropped telemetry event beats an unparseable line on the bus, and
# both callers in prompt-rule-injector.sh already discard the return with
# `|| true` so a rejection can never block prompt submission.
#
# Usage: prompt_rules_emit "$session_id" "prompt_rule.matched" "$payload_json"
prompt_rules_emit() {
  local session_id="${1:-unknown}"
  local event_type="${2:-}"
  # Default the payload without inlining braces in the expansion. Both
  # `${3:-{\}}` and `${3:-{}}` are wrong: the first keeps the backslash on
  # bash 3.2 (macOS system bash), and the second appends a stray `}` to any
  # payload that IS supplied, on every bash version.
  local payload_json="${3:-}"
  [ -z "$payload_json" ] && payload_json='{}'
  [[ -z "$event_type" ]] && return 1

  local event_js="$_PROMPT_RULES_EVENT_JS"
  [[ -n "${_ONLOOKER_EVENT_JS:-}" && -f "${_ONLOOKER_EVENT_JS}" ]] && event_js="$_ONLOOKER_EVENT_JS"
  [[ -f "$event_js" ]] || return 1

  local plugin
  plugin="${ONLOOKER_PLUGIN_NAME:-onlooker}"

  local params
  params=$(jq -cn \
    --arg plugin "$plugin" \
    --arg sid "$session_id" \
    --arg type "$event_type" \
    --argjson payload "$payload_json" \
    '{plugin: $plugin, session_id: $sid, event_type: $type, payload: $payload}') || return 1

  local event
  event=$(printf '%s' "$params" \
    | ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="$plugin" \
      node "$event_js" emit 2>/dev/null) || return 1
  [[ -z "$event" ]] && return 1

  ensure_file_exists "$ONLOOKER_EVENTS_LOG" || return 1
  printf '%s\n' "$event" >> "$ONLOOKER_EVENTS_LOG"
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

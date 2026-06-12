#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  # shellcheck source=../../scripts/lib/onlooker-schema.sh
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
  # shellcheck source=../../scripts/lib/tool-history.sh
  source "${REPO_ROOT}/scripts/lib/tool-history.sh"
  # shellcheck source=../../scripts/lib/skill-usage.sh
  source "${REPO_ROOT}/scripts/lib/skill-usage.sh"
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
}

@test "skill_usage_build_record maps UserPromptExpansion to skill.invoked" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-expansion-skill.json"
  local record
  record=$(skill_usage_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.schema_version == "1.0"
     and .event_type == "skill.invoked"
     and .payload.skill_name == "code-review"
     and .payload.invocation_source == "slash_command"
     and .payload.command_args == "src/main.ts"
     and .payload.expansion_type == "slash_command"
     and .session_id == "skill-session-001"' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "skill_usage_build_record maps PreToolUse Skill to skill.invoked" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/pre-tool-use-skill.json"
  local record
  record=$(skill_usage_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.event_type == "skill.invoked"
     and .payload.skill_name == "code-review"
     and .payload.invocation_source == "tool"
     and .payload.command_args == "src/main.ts"' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "skill-usage-tracker appends slash command skill to session JSONL" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-expansion-skill.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/skill-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/skill-usage-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -f "$history_file" ]
  tail -n 1 "$history_file" | jq -e '.event_type == "skill.invoked"' >/dev/null
  tail -n 1 "$history_file" | onlooker_validate_event
}

@test "skill-usage-tracker approves PreToolUse Skill and records event" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/pre-tool-use-skill.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/skill-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/skill-usage-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "approve"' >/dev/null
  tail -n 1 "$history_file" | jq -e '.payload.invocation_source == "tool"' >/dev/null
}

@test "skill-usage-tracker mirrors skill.invoked to global events log" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-expansion-skill.json"
  : >"$ONLOOKER_EVENTS_LOG"

  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/skill-usage-tracker.sh" >/dev/null 2>&1

  tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -e '.event_type == "skill.invoked"' >/dev/null
  tail -n 1 "$ONLOOKER_EVENTS_LOG" | onlooker_validate_event
}

@test "skill_usage_append writes a built skill.invoked record to the session history file" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-expansion-skill.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/skill-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  local record
  record=$(skill_usage_build_record "$(cat "$fixture")")

  run skill_usage_append "skill-session-001" "$record"
  [ "$status" -eq 0 ]

  [ -f "$history_file" ]
  tail -n 1 "$history_file" | jq -e \
    '.event_type == "skill.invoked"
     and .payload.skill_name == "code-review"
     and .payload.invocation_source == "slash_command"
     and .session_id == "skill-session-001"' \
    >/dev/null
  tail -n 1 "$history_file" | onlooker_validate_event
}

@test "skill_usage_append routes the record to the per-session file named after the session id" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/pre-tool-use-skill.json"
  local session_id="skill-session-custom"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${session_id}.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  # Build a canonical record, then retarget its session_id; skill_usage_append
  # must file it under the session_id argument, not the embedded one.
  local record
  record=$(skill_usage_build_record "$(cat "$fixture")" \
    | jq -c --arg sid "$session_id" '.session_id = $sid')

  run skill_usage_append "$session_id" "$record"
  [ "$status" -eq 0 ]

  [ -f "$history_file" ]
  [ "$(wc -l <"$history_file")" -eq 1 ]
  tail -n 1 "$history_file" | jq -e \
    '.session_id == "skill-session-custom"
     and .payload.skill_name == "code-review"
     and .payload.invocation_source == "tool"' \
    >/dev/null
  tail -n 1 "$history_file" | onlooker_validate_event
}

@test "skill_usage_append is a no-op when the session id is empty" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/pre-tool-use-skill.json"
  local record
  record=$(skill_usage_build_record "$(cat "$fixture")")

  # Snapshot the history dir, then assert the empty-session call adds nothing.
  local before
  before=$(find "$ONLOOKER_SESSION_HISTORY_DIR" -type f | sort)

  run skill_usage_append "" "$record"
  [ "$status" -eq 0 ]

  local after
  after=$(find "$ONLOOKER_SESSION_HISTORY_DIR" -type f | sort)
  [ "$before" = "$after" ]
}

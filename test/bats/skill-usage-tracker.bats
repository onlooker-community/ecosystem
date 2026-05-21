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

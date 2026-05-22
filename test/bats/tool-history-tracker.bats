#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  # shellcheck source=../../scripts/lib/onlooker-schema.sh
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
  # shellcheck source=../../scripts/lib/tool-history.sh
  source "${REPO_ROOT}/scripts/lib/tool-history.sh"
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
}

@test "tool_history_build_record returns canonical tool.file.read event" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-read.json"
  local record
  record=$(tool_history_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.schema_version == "1.0"
     and .event_type == "tool.file.read"
     and .payload.path == "/project/src/main.ts"
     and .payload.read_mode == "full"
     and .session_id == "history-session-001"' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "tool_history_build_record returns canonical tool.shell.exec on failure" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-failure-bash.json"
  local record
  record=$(tool_history_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.event_type == "tool.shell.exec"
     and .payload.command == "npm test"
     and .payload.blocked == true' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "tool-history-tracker appends canonical PostToolUse event to session JSONL" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-read.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/history-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/tool-history-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -f "$history_file" ]
  tail -n 1 "$history_file" | jq -e '.event_type == "tool.file.read"' >/dev/null
  tail -n 1 "$history_file" | onlooker_validate_event
}

@test "tool-history-tracker mirrors event to global onlooker-events log" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-read.json"
  : >"$ONLOOKER_EVENTS_LOG"

  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/tool-history-tracker.sh" >/dev/null 2>&1

  tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -e '.event_type == "tool.file.read"' >/dev/null
  tail -n 1 "$ONLOOKER_EVENTS_LOG" | onlooker_validate_event
}

@test "tool-history-tracker appends multiple canonical records for same session" {
  local read_fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-read.json"
  local fail_fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-failure-bash.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/history-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  cat "$read_fixture" | "${REPO_ROOT}/scripts/hooks/tool-history-tracker.sh" >/dev/null 2>&1
  cat "$fail_fixture" | "${REPO_ROOT}/scripts/hooks/tool-history-tracker.sh" >/dev/null 2>&1

  run wc -l <"$history_file"
  [ "$output" -eq 2 ]
}

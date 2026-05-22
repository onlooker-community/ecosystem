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

  LARGE_FILE="${BATS_TEST_TMPDIR}/large-source.ts"
  # > LARGE_FILE_BYTES_ON_DISK (100_000) for large_file_full_read
  printf '%*s\n' 120000 "" >"$LARGE_FILE"
}

@test "tool_history maps full Read to read_mode full" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-read.json"
  local record
  record=$(tool_history_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.payload.read_mode == "full"
     and .payload.path == "/project/src/main.ts"
     and (.payload.large_file_full_read | not)' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "tool_history maps chunked Read to read_mode partial with offset and limit" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-read-chunked.json"
  local record
  record=$(tool_history_build_record "$(cat "$fixture")")
  echo "$record" | jq -e \
    '.payload.read_mode == "partial"
     and .payload.offset == 400
     and .payload.limit == 80
     and .payload.lines_read == 3' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "tool_history flags large_file_full_read for full read of large on-disk file" {
  local input
  input=$(jq -n \
    --arg path "$LARGE_FILE" \
    --arg content "peek\n" \
    '{
      session_id: "history-session-002",
      hook_event_name: "PostToolUse",
      tool_name: "Read",
      tool_input: {file_path: $path},
      tool_response: {content: $content}
    }')
  local record
  record=$(tool_history_build_record "$input")
  echo "$record" | jq -e \
    '.payload.read_mode == "full"
     and .payload.large_file_full_read == true
     and .payload.file_bytes_on_disk > 100000' \
    >/dev/null
  echo "$record" | onlooker_validate_event
}

@test "tool-history-tracker appends chunked read to session JSONL" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-tool-use-read-chunked.json"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/history-session-001.jsonl"
  rm -f "$history_file" "${history_file}.lock"

  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/tool-history-tracker.sh" >/dev/null 2>&1

  tail -n 1 "$history_file" | jq -e '.payload.read_mode == "partial"' >/dev/null
}

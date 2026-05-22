#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
  source "${REPO_ROOT}/scripts/lib/tool-history.sh"
  source "${REPO_ROOT}/scripts/lib/session-tracker.sh"
  source "${REPO_ROOT}/scripts/lib/compact-tracker.sh"
}

@test "pre-compact-tracker approves and records pending compact state" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/pre-compact-manual.json"
  local session_id="compact-session-001"
  local transcript="/tmp/onlooker-compact-transcript-${BATS_TEST_NUMBER}.jsonl"
  local state_file="${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}"

  printf '%s\n' '{"type":"user","message":"hello"}' '{"type":"assistant","message":"world"}' >"$transcript"
  local runtime_input="${BATS_TEST_TMPDIR}/pre-compact-input.json"
  jq --arg path "$transcript" '.transcript_path = $path' "$fixture" >"$runtime_input"
  rm -f "$state_file"

  run bash -c "cat '${runtime_input}' | '${REPO_ROOT}/scripts/hooks/pre-compact-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "approve"' >/dev/null

  jq -e '.pending == true
    and .trigger == "manual"
    and .compact_count == 1
    and (.tokens_before | type) == "number"' \
    "$state_file" >/dev/null

  rm -f "$transcript"
}

@test "context-compact-tracker emits session.compact and saves summary" {
  local pre_fixture="${REPO_ROOT}/test/fixtures/hook-inputs/pre-compact-manual.json"
  local post_fixture="${REPO_ROOT}/test/fixtures/hook-inputs/post-compact-manual.json"
  local session_id="compact-session-001"
  local transcript="/tmp/onlooker-compact-transcript-post-${BATS_TEST_NUMBER}.jsonl"
  local state_file="${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}"
  local history_file="${ONLOOKER_SESSION_HISTORY_DIR}/${session_id}.jsonl"
  local summary_file="${ONLOOKER_SESSION_SUMMARIES_DIR}/${session_id}.jsonl"

  printf '%s\n' '{"type":"user","message":"long context"}' >"$transcript"
  local pre_input post_input
  pre_input=$(jq --arg path "$transcript" '.transcript_path = $path' "$pre_fixture")
  post_input=$(jq --arg path "$transcript" '.transcript_path = $path' "$post_fixture")

  rm -f "$state_file" "$history_file" "$summary_file"
  printf '%s' "$pre_input" | "${REPO_ROOT}/scripts/hooks/pre-compact-tracker.sh" >/dev/null 2>&1

  local post_runtime="${BATS_TEST_TMPDIR}/post-compact-input.json"
  printf '%s' "$post_input" >"$post_runtime"
  run bash -c "cat '${post_runtime}' | '${REPO_ROOT}/scripts/hooks/context-compact-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]

  jq -e '.pending == false and .last_trigger == "manual"' "$state_file" >/dev/null
  jq -e '.event_type == "session.compact"
    and (.payload.tokens_before >= .payload.tokens_after)
    and (.payload.compression_ratio | type) == "number"' \
    "$history_file" >/dev/null
  run jq -e '.compact_summary | length > 0' "$summary_file"
  [ "$status" -eq 0 ]

  rm -f "$transcript"
}

@test "compact_tracker_estimate_tokens estimates from string length" {
  [ "$(compact_tracker_estimate_tokens "abcdefghij" false)" -eq 2 ]
}

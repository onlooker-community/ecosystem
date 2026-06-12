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

@test "compact_tracker_state_file prints path under compact trackers dir" {
  local session_id="unit-state-file"
  local result
  result=$(compact_tracker_state_file "$session_id")
  [ "$result" = "${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}" ]
}

@test "compact_tracker_record_pre creates state file with pending and compact_count 1" {
  local session_id="unit-record-pre-1"
  local state_file="${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}"
  rm -f "$state_file"

  compact_tracker_record_pre "$session_id" '{"trigger":"manual","transcript_path":""}'

  [ -f "$state_file" ]
  jq -e '.pending == true
    and .trigger == "manual"
    and .compact_count == 1
    and (.started_ms | type) == "number"' \
    "$state_file" >/dev/null
}

@test "compact_tracker_record_pre increments compact_count on second call" {
  local session_id="unit-record-pre-2"
  local state_file="${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}"
  rm -f "$state_file"

  compact_tracker_record_pre "$session_id" '{"trigger":"manual","transcript_path":""}'
  jq -e '.compact_count == 1' "$state_file" >/dev/null

  compact_tracker_record_pre "$session_id" '{"trigger":"manual","transcript_path":""}'
  jq -e '.compact_count == 2' "$state_file" >/dev/null
}

@test "compact_tracker_record_pre preserves custom_instructions when present" {
  local session_id="unit-record-pre-3"
  local state_file="${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}"
  rm -f "$state_file"

  compact_tracker_record_pre "$session_id" \
    '{"trigger":"manual","transcript_path":"","custom_instructions":"keep the API design notes"}'

  jq -e '.custom_instructions == "keep the API design notes"' "$state_file" >/dev/null
}

@test "compact_tracker_append_summary appends a JSONL record" {
  local session_id="unit-append-1"
  local summary_file="${ONLOOKER_SESSION_SUMMARIES_DIR}/${session_id}.jsonl"
  rm -f "$summary_file"

  compact_tracker_append_summary "$session_id" \
    '{"trigger":"manual","compact_summary":"first summary"}'

  [ -f "$summary_file" ]
  # Records are written as a JSON stream; count objects rather than physical lines.
  [ "$(jq -s 'length' "$summary_file")" -eq 1 ]
  jq -se '.[0].compact_summary == "first summary" and .[0].trigger == "manual"' "$summary_file" >/dev/null
}

@test "compact_tracker_append_summary appends a second line on second call" {
  local session_id="unit-append-2"
  local summary_file="${ONLOOKER_SESSION_SUMMARIES_DIR}/${session_id}.jsonl"
  rm -f "$summary_file"

  compact_tracker_append_summary "$session_id" '{"trigger":"manual","compact_summary":"one"}'
  compact_tracker_append_summary "$session_id" '{"trigger":"auto","compact_summary":"two"}'

  [ "$(jq -s 'length' "$summary_file")" -eq 2 ]
  [ "$(jq -s -r '.[0].compact_summary' "$summary_file")" = "one" ]
  [ "$(jq -s -r '.[1].trigger' "$summary_file")" = "auto" ]
}

@test "compact_tracker_append_summary is a no-op when compact_summary is empty" {
  local session_id="unit-append-3"
  local summary_file="${ONLOOKER_SESSION_SUMMARIES_DIR}/${session_id}.jsonl"
  rm -f "$summary_file"

  run compact_tracker_append_summary "$session_id" '{"trigger":"manual","compact_summary":""}'
  [ "$status" -eq 0 ]
  [ ! -f "$summary_file" ]
}

@test "compact_tracker_build_compact_payload uses tokens_before from state file" {
  local session_id="unit-build-payload"
  local state_file="${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}"
  printf '%s\n' '{"tokens_before":1000}' >"$state_file"

  local payload
  payload=$(compact_tracker_build_compact_payload "$session_id" \
    '{"compact_summary":"a short compacted summary of the prior context"}')

  echo "$payload" | jq -e '.tokens_before == 1000
    and (.tokens_after | type) == "number"
    and (.compression_ratio | type) == "number"' >/dev/null
}

@test "compact_tracker_record_post finalizes state and resets turn_tool_seq" {
  local session_id="unit-record-post-1"
  local state_file="${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}"
  local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"

  printf '%s\n' '{"pending":true,"started_ms":1700000000000,"compact_count":1}' >"$state_file"
  printf '%s\n' '{"turn_number":3,"turn_tool_seq":5}' >"$tracker_file"

  compact_tracker_record_post "$session_id" '{"trigger":"manual","compact_summary":"done"}'

  jq -e '.pending == false and (.completed_ms | type) == "number"' "$state_file" >/dev/null
  jq -e '.turn_tool_seq == 0 and .turn_number == 3' "$tracker_file" >/dev/null
}

@test "compact_tracker_record_post falls back to create state when none exists" {
  local session_id="unit-record-post-2"
  local state_file="${ONLOOKER_COMPACT_TRACKERS_DIR}/${session_id}"
  local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  rm -f "$state_file" "$tracker_file"

  compact_tracker_record_post "$session_id" '{"trigger":"auto","compact_summary":"recovered"}'

  [ -f "$state_file" ]
  jq -e '.pending == false
    and (.completed_ms | type) == "number"
    and .compact_count == 1' \
    "$state_file" >/dev/null
}

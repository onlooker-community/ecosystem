#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
  # shellcheck source=../../scripts/lib/onlooker-schema.sh
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
  # shellcheck source=../../scripts/lib/tool-history.sh
  source "${REPO_ROOT}/scripts/lib/tool-history.sh"
  # shellcheck source=../../scripts/lib/session-tracker.sh
  source "${REPO_ROOT}/scripts/lib/session-tracker.sh"
  # shellcheck source=../../scripts/lib/turn-tracker.sh
  source "${REPO_ROOT}/scripts/lib/turn-tracker.sh"
}

# ── turn_tracker_summarize_prompt ──────────────────────────────────────────

@test "turn_tracker_summarize_prompt collapses newlines and runs of spaces" {
  local out
  out=$(turn_tracker_summarize_prompt $'hello\n\nworld   foo')
  [ "$out" = "hello world foo" ]
}

@test "turn_tracker_summarize_prompt trims leading and trailing spaces" {
  local out
  out=$(turn_tracker_summarize_prompt "  padded text  ")
  [ "$out" = "padded text" ]
}

@test "turn_tracker_summarize_prompt leaves a short prompt unchanged" {
  local out
  out=$(turn_tracker_summarize_prompt "fix the bug")
  [ "$out" = "fix the bug" ]
}

@test "turn_tracker_summarize_prompt does not truncate input of exactly 200 chars" {
  local exact
  exact=$(printf 'b%.0s' {1..200})
  local out
  out=$(turn_tracker_summarize_prompt "$exact")
  [ "${#out}" -eq 200 ]
  [[ "$out" != *…* ]]
}

@test "turn_tracker_summarize_prompt truncates to 200 chars plus an ellipsis when over 200" {
  local long
  long=$(printf 'a%.0s' {1..300})
  local out
  out=$(turn_tracker_summarize_prompt "$long")
  # 200 retained characters + the single-character ellipsis = length 201.
  [ "${#out}" -eq 201 ]
  [[ "$out" == *… ]]
  [ "${out%…}" = "$(printf 'a%.0s' {1..200})" ]
}

@test "turn_tracker_summarize_prompt returns empty and succeeds on empty input" {
  run turn_tracker_summarize_prompt ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── turn_tracker_on_user_prompt ────────────────────────────────────────────

@test "turn_tracker_on_user_prompt keeps turn 1 and marks prompts seen on first prompt" {
  local sid="turn-first-001"
  turn_tracker_on_user_prompt "$sid"

  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  [ -f "$tracker" ]
  jq -e '.turn_number == 1
    and .user_prompts_seen == true
    and .turn_tool_seq == 0' "$tracker" >/dev/null
}

@test "turn_tracker_on_user_prompt advances the turn on the second prompt" {
  local sid="turn-second-001"
  turn_tracker_on_user_prompt "$sid"
  turn_tracker_on_user_prompt "$sid"

  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  jq -e '.turn_number == 2
    and .user_prompts_seen == true
    and .turn_tool_seq == 0' "$tracker" >/dev/null
}

@test "turn_tracker_on_user_prompt increments once per subsequent prompt" {
  local sid="turn-many-001"
  turn_tracker_on_user_prompt "$sid"  # turn 1, marks seen
  turn_tracker_on_user_prompt "$sid"  # turn 2
  turn_tracker_on_user_prompt "$sid"  # turn 3
  turn_tracker_on_user_prompt "$sid"  # turn 4

  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  jq -e '.turn_number == 4' "$tracker" >/dev/null
}

@test "turn_tracker_on_user_prompt no-ops on empty session_id" {
  run turn_tracker_on_user_prompt ""
  [ "$status" -eq 0 ]
  # No tracker file should have been created for an empty id.
  [ ! -f "${ONLOOKER_SESSION_TRACKERS_DIR}/" ]
  [ -z "$(ls -A "${ONLOOKER_SESSION_TRACKERS_DIR}")" ]
}

@test "turn_tracker_on_user_prompt no-ops on null session_id" {
  run turn_tracker_on_user_prompt "null"
  [ "$status" -eq 0 ]
  [ ! -f "${ONLOOKER_SESSION_TRACKERS_DIR}/null" ]
}

# ── turn_tracker_build_prompt_payload ──────────────────────────────────────

@test "turn_tracker_build_prompt_payload reads turn_number from the tracker and includes input_summary" {
  local sid="payload-001"
  turn_state_ensure_session "$sid"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"
  jq '.turn_number = 5' "$tracker" >"${tracker}.tmp"
  mv "${tracker}.tmp" "$tracker"

  local payload
  payload=$(turn_tracker_build_prompt_payload "$sid" $'review   the\n\ndiff')
  echo "$payload" | jq -e '.turn_number == 5
    and .input_summary == "review the diff"' >/dev/null
}

@test "turn_tracker_build_prompt_payload defaults turn_number to 1 when tracker is missing" {
  local sid="payload-missing"
  rm -f "${ONLOOKER_SESSION_TRACKERS_DIR}/${sid}"

  local payload
  payload=$(turn_tracker_build_prompt_payload "$sid" "hello")
  echo "$payload" | jq -e '.turn_number == 1 and .input_summary == "hello"' >/dev/null
}

@test "turn_tracker_build_prompt_payload omits input_summary for an empty prompt" {
  local sid="payload-empty"
  turn_state_ensure_session "$sid"

  local payload
  payload=$(turn_tracker_build_prompt_payload "$sid" "")
  echo "$payload" | jq -e '.turn_number == 1 and (has("input_summary") | not)' >/dev/null
}

@test "turn_tracker_build_prompt_payload truncates a long prompt in input_summary" {
  local sid="payload-long"
  turn_state_ensure_session "$sid"
  local long
  long=$(printf 'x%.0s' {1..300})

  local payload summary
  payload=$(turn_tracker_build_prompt_payload "$sid" "$long")
  summary=$(echo "$payload" | jq -r '.input_summary')
  [ "${#summary}" -eq 201 ]
  [[ "$summary" == *… ]]
}

@test "turn_tracker_build_prompt_payload returns 1 for null session_id" {
  run turn_tracker_build_prompt_payload "null" "hi"
  [ "$status" -eq 1 ]
}

@test "turn_tracker_build_prompt_payload returns 1 for empty session_id" {
  run turn_tracker_build_prompt_payload "" "hi"
  [ "$status" -eq 1 ]
}

# ── integration: orchestrator + payload reflect the same turn ──────────────

@test "turn_tracker payload reflects turn advanced by turn_tracker_on_user_prompt" {
  local sid="turn-integration-001"
  # Two prompts -> turn 2; payload built afterward should report turn 2.
  turn_tracker_on_user_prompt "$sid"
  turn_tracker_on_user_prompt "$sid"

  local payload
  payload=$(turn_tracker_build_prompt_payload "$sid" "second prompt")
  echo "$payload" | jq -e '.turn_number == 2 and .input_summary == "second prompt"' >/dev/null
}

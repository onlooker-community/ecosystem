#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  # shellcheck source=../../scripts/lib/onlooker-schema.sh
  source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
}

@test "validate_file_exists succeeds for existing file" {
  local f="${BATS_TEST_TMPDIR}/exists.txt"
  touch "$f"
  validate_file_exists "$f"
  [ "$?" -eq 0 ]
}

@test "validate_file_exists fails for missing file" {
  ! validate_file_exists "${BATS_TEST_TMPDIR}/missing.txt"
}

@test "validate_dir_exists succeeds for existing directory" {
  validate_dir_exists "${BATS_TEST_TMPDIR}"
  [ "$?" -eq 0 ]
}

@test "ensure_dir_exists creates missing directory" {
  local dir="${BATS_TEST_TMPDIR}/nested/new-dir"
  ensure_dir_exists "$dir"
  [ "$?" -eq 0 ]
  [ -d "$dir" ]
}

@test "ensure_file_exists creates file and parent directories" {
  local f="${BATS_TEST_TMPDIR}/deep/path/file.txt"
  ensure_file_exists "$f"
  [ "$?" -eq 0 ]
  [ -f "$f" ]
}

@test "safe_append writes content to file" {
  local f="${BATS_TEST_TMPDIR}/append.txt"
  safe_append "$f" "line-one"
  safe_append "$f" "line-two"
  grep -q "line-one" "$f"
  grep -q "line-two" "$f"
}

@test "safe_tail returns last N lines" {
  local f="${BATS_TEST_TMPDIR}/tail.txt"
  printf '%s\n' one two three four >"$f"
  local result
  result=$(safe_tail "$f" 2)
  [ "$result" = $'three\nfour' ]
}

@test "hook_set_context exports session and tool from JSON" {
  local input='{"session_id":"sess-42","tool_name":"Agent"}'
  hook_set_context "$input" "PreToolUse"
  [ "${ONLOOKER_HOOK_TYPE}" = "PreToolUse" ]
  [ "${ONLOOKER_TOOL_NAME}" = "Agent" ]
  [ "${_HOOK_SESSION_ID}" = "sess-42" ]
}

@test "hook_bus put/get round-trip" {
  export _HOOK_SESSION_ID="bus-session"
  export _HOOK_TOOL_NAME="Agent"
  hook_bus_init '{"tool_input":{"agent_id":"1"}}'
  hook_bus_put "scanner" '{"found":true}'
  local result
  result=$(hook_bus_get "scanner")
  echo "$result" | jq -e '.found == true' >/dev/null
}

@test "hook_bus_has detects existing finding" {
  export _HOOK_SESSION_ID="bus-session-2"
  export _HOOK_TOOL_NAME="Agent"
  hook_bus_init '{"tool_input":{"agent_id":"2"}}'
  hook_bus_put "flag" '{"ok":true}'
  hook_bus_has "flag"
  [ "$?" -eq 0 ]
  ! hook_bus_has "missing"
}

@test "turn_state_export reads turn numbers from tracker file" {
  local session_id="turn-test-session"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  mkdir -p "$(dirname "$tracker")"
  echo '{"turn_number":3,"turn_tool_seq":2}' >"$tracker"
  turn_state_export "$session_id"
  [ "${ONLOOKER_TURN_NUMBER}" = "3" ]
  [ "${ONLOOKER_TURN_TOOL_SEQ}" = "2" ]
}

@test "safe_emit appends canonical event to onlooker events log" {
  export _HOOK_SESSION_ID="emit-session"
  export ONLOOKER_HOOK_TYPE="PreToolUse"
  export ONLOOKER_TOOL_NAME="Read"
  local payload='{"path":"/tmp/example.txt","read_mode":"full"}'
  safe_emit "tool.file.read" "$payload"
  [ "$?" -eq 0 ]
  [ -f "$ONLOOKER_EVENTS_LOG" ]
  tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -e \
    '.event_type == "tool.file.read"
     and .session_id == "emit-session"
     and .payload.path == "/tmp/example.txt"
     and .schema_version == "1.0"' \
    >/dev/null
}

# ----------------------------------------------------------------------------
# Hook health instrumentation: hook_register / hook_success / hook_failure
# ----------------------------------------------------------------------------

@test "hook_register seeds hook name and start time" {
  hook_register "my-hook" "My Hook" "A description"
  trap - EXIT  # disarm the trap hook_register installed so it can't fire later
  [ "${_HOOK_NAME}" = "my-hook" ]
  [ -n "${_HOOK_START_TIME}" ]
}

@test "hook_success writes a success record to the hook-health log" {
  export _HOOK_SESSION_ID="health-success-session"
  hook_register "success-hook"
  hook_success
  [ -f "$ONLOOKER_HOOK_HEALTH_LOG" ]
  tail -n 1 "$ONLOOKER_HOOK_HEALTH_LOG" | jq -e \
    '.hook == "success-hook"
     and .status == "success"
     and .error == null
     and .session_id == "health-success-session"' \
    >/dev/null
}

@test "hook_failure writes a failure record with the error message" {
  hook_register "failure-hook"
  hook_failure "boom: it broke"
  [ -f "$ONLOOKER_HOOK_HEALTH_LOG" ]
  tail -n 1 "$ONLOOKER_HOOK_HEALTH_LOG" | jq -e \
    '.hook == "failure-hook"
     and .status == "failure"
     and .error == "boom: it broke"' \
    >/dev/null
}

@test "hook_health_summary reflects seeded success and failure records" {
  # Two records for the same hook: one success, one failure.
  hook_register "summary-hook"
  hook_success
  hook_register "summary-hook"
  hook_failure "an error"

  local summary
  summary=$(hook_health_summary 24)
  echo "$summary" | jq -e \
    'map(select(.hook == "summary-hook"))
     | .[0]
     | .total == 2
     and .success == 1
     and .failure == 1
     and .last_error == "an error"' \
    >/dev/null
}

# ----------------------------------------------------------------------------
# Hook composition bus: hook_bus_list / hook_bus_cleanup
# ----------------------------------------------------------------------------

@test "hook_bus_list lists put findings without the .json extension" {
  export _HOOK_SESSION_ID="bus-list-session"
  export _HOOK_TOOL_NAME="Agent"
  hook_bus_init '{"tool_input":{"agent_id":"list"}}'
  hook_bus_put "alpha" '{"a":1}'
  hook_bus_put "beta" '{"b":2}'
  local listing
  listing=$(hook_bus_list | sort | tr '\n' ' ')
  [ "$listing" = "alpha beta " ]
}

@test "hook_bus_cleanup removes aged bus dirs but keeps fresh ones" {
  local tmp_dir
  tmp_dir="$(cd /tmp && pwd -P)"
  local fresh="${tmp_dir}/.onlooker-hook-bus-cleanup-fresh-$$"
  local aged="${tmp_dir}/.onlooker-hook-bus-cleanup-aged-$$"
  mkdir -p "$fresh" "$aged"
  # Backdate the aged dir well past the 5-minute (-mmin +5) cutoff.
  touch -t "$(date -v-10M +%Y%m%d%H%M.%S 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M.%S)" "$aged"

  hook_bus_cleanup

  [ ! -d "$aged" ]
  [ -d "$fresh" ]
  rm -rf "$fresh"
}

# ----------------------------------------------------------------------------
# Readability / writability validators
# ----------------------------------------------------------------------------

@test "validate_file_readable succeeds for existing readable file" {
  local f="${BATS_TEST_TMPDIR}/readable.txt"
  touch "$f"
  validate_file_readable "$f"
  [ "$?" -eq 0 ]
}

@test "validate_file_readable fails for missing file" {
  ! validate_file_readable "${BATS_TEST_TMPDIR}/no-such-file.txt"
}

@test "validate_file_writable succeeds when parent directory is writable" {
  validate_file_writable "${BATS_TEST_TMPDIR}/new-file.txt"
  [ "$?" -eq 0 ]
}

@test "validate_file_writable fails when parent directory does not exist" {
  ! validate_file_writable "${BATS_TEST_TMPDIR}/missing-dir/new-file.txt"
}

# ----------------------------------------------------------------------------
# Turn state tracking: turn_state_next_turn
# ----------------------------------------------------------------------------

@test "turn_state_next_turn increments turn_number from 1 to 2" {
  local session_id="next-turn-session"
  local tracker="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
  turn_state_ensure_session "$session_id"
  [ -f "$tracker" ]
  # Fresh session starts at turn_number 1.
  jq -e '.turn_number == 1' "$tracker" >/dev/null

  turn_state_next_turn "$session_id"
  jq -e '.turn_number == 2 and .turn_tool_seq == 0' "$tracker" >/dev/null
}

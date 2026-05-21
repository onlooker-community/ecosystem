#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
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

@test "safe_emit appends event to onlooker events log" {
  export ONLOOKER_HOOK_TYPE="PreToolUse"
  export ONLOOKER_TOOL_NAME="Agent"
  local payload='{"session_id":"emit-session","hello":"world"}'
  safe_emit "test.event" "$payload"
  [ "$?" -eq 0 ]
  [ -f "$ONLOOKER_EVENTS_LOG" ]
  tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -e \
    '.event_type == "test.event"
     and .session_id == "emit-session"
     and .payload.hello == "world"' \
    >/dev/null
}

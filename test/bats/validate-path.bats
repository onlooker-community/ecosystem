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

@test "safe_emit's line validates as a canonical envelope, not just a lookalike" {
  # The assertion above spot-checks four fields. A hand-built envelope can pass
  # that while still being rejected by the schema, which is exactly how the
  # fallback below stayed broken. Validate the whole line instead.
  export _HOOK_SESSION_ID="emit-session"
  safe_emit "tool.file.read" '{"path":"/tmp/example.txt","read_mode":"full"}'
  tail -n 1 "$ONLOOKER_EVENTS_LOG" \
    | ONLOOKER_DIR="$ONLOOKER_DIR" node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

@test "safe_emit writes nothing when the emit script is missing" {
  # The degraded path. It used to hand-build an envelope with jq that omitted
  # every required id/schema_version/runtime/machine_id/sequence field and added
  # four the schema forbids (hook_type, tool_name, turn, tool_call_seq), on an
  # envelope that is additionalProperties:false. An unparseable line on the bus
  # is worse than a missing one, so this path now writes nothing at all.
  # See ecosystem-0tm.
  export _HOOK_SESSION_ID="emit-session"
  export ONLOOKER_HOOK_TYPE="PreToolUse"
  export ONLOOKER_TOOL_NAME="Read"
  export ONLOOKER_TURN_NUMBER=4
  export ONLOOKER_TURN_TOOL_SEQ=2
  export ONLOOKER_EMIT="${BATS_TEST_TMPDIR}/no-such-emit.sh"

  : >"$ONLOOKER_EVENTS_LOG"
  run safe_emit "tool.file.read" '{"path":"/tmp/example.txt","read_mode":"full"}'
  [ "$status" -ne 0 ] || return 1
  [ ! -s "$ONLOOKER_EVENTS_LOG" ]
}

@test "safe_emit's failure to emit never aborts the calling hook" {
  # safe_emit is substrate: returning non-zero must be absorbable by a caller
  # running under `set -e`, the shape every hook uses. Assert the caller
  # survives and reaches its next statement.
  export ONLOOKER_EMIT="${BATS_TEST_TMPDIR}/no-such-emit.sh"
  run bash -c "
    set -euo pipefail
    source '${REPO_ROOT}/scripts/lib/validate-path.sh'
    export ONLOOKER_EMIT='${BATS_TEST_TMPDIR}/no-such-emit.sh'
    safe_emit 'tool.file.read' '{\"path\":\"/x\",\"read_mode\":\"full\"}' || true
    echo REACHED
  "
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"REACHED"* ]]
}

# ----------------------------------------------------------------------------
# Hook health instrumentation: hook_register / hook_success / hook_failure
# ----------------------------------------------------------------------------

@test "hook_register seeds hook name and start time" {
  hook_register "my-hook" "My Hook" "A description"
  trap - EXIT  # disarm the trap hook_register installed so it can't fire later
  [ "${_HOOK_NAME}" = "my-hook" ]
  [ -n "${_HOOK_START_MS}" ]
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

# An unmeasurable duration is written as null (ecosystem-449.7). jq's `add`
# treats null as identity but `length` still counts it, so averaging naively
# divides a correct sum by an inflated count and under-reports every hook that
# ever failed to measure. The rollout sets latency budgets off this number.
@test "hook_health_summary excludes unmeasurable records from the average" {
  # Two measurable records at a known duration, one unmeasurable.
  hook_register "avg-hook"
  _HOOK_START_MS=$(( $(_hook_health_now_ms) - 100 ))
  hook_success
  hook_register "avg-hook"
  _HOOK_START_MS=$(( $(_hook_health_now_ms) - 100 ))
  hook_success
  hook_register "avg-hook"
  _HOOK_START_MS="not-a-number"
  hook_success

  local summary
  summary=$(hook_health_summary 24)
  # The average must come from the two measurable records (~100ms), not be
  # dragged toward zero by dividing their sum by three.
  echo "$summary" | jq -e \
    'map(select(.hook == "avg-hook"))
     | .[0]
     | .total == 3
     and .unmeasurable == 1
     and .avg_duration_ms >= 90' \
    >/dev/null
}

@test "hook_health_summary reports null average when nothing was measurable" {
  hook_register "all-bad-hook"
  _HOOK_START_MS="not-a-number"
  hook_success

  local summary
  summary=$(hook_health_summary 24)
  echo "$summary" | jq -e \
    'map(select(.hook == "all-bad-hook"))
     | .[0]
     | .unmeasurable == 1 and .avg_duration_ms == null' \
    >/dev/null
}

# ecosystem-449.6. The derived path exports were unconditional, so a caller who
# set ONLOOKER_HOOK_HEALTH_LOG had it silently overwritten the moment anything
# sourced validate-path.sh — you could not redirect one hook's records without
# moving the whole ONLOOKER_DIR.
#
# The guard has to cut both ways. Honoring an explicit override is the point;
# but the derived paths must still FOLLOW ONLOOKER_DIR when nothing set them,
# because that invariant is what keeps every test in this suite inside its temp
# home. setup_test_env therefore clears them, so a value inherited from an
# outer shell cannot survive into an isolated run.
@test "an explicit ONLOOKER_HOOK_HEALTH_LOG override survives sourcing validate-path" {
  local custom="${BATS_TEST_TMPDIR}/custom-health.jsonl"
  run bash -c "
    export ONLOOKER_DIR='${ONLOOKER_DIR}'
    export ONLOOKER_HOOK_HEALTH_LOG='${custom}'
    source '${REPO_ROOT}/scripts/lib/validate-path.sh'
    printf '%s' \"\$ONLOOKER_HOOK_HEALTH_LOG\"
  "
  [ "$output" = "$custom" ]
}

@test "derived paths follow ONLOOKER_DIR when nothing overrode them" {
  local elsewhere="${BATS_TEST_TMPDIR}/elsewhere"
  run bash -c "
    unset ONLOOKER_HOOK_HEALTH_LOG ONLOOKER_EVENTS_LOG
    export ONLOOKER_DIR='${elsewhere}'
    source '${REPO_ROOT}/scripts/lib/validate-path.sh'
    printf '%s|%s' \"\$ONLOOKER_HOOK_HEALTH_LOG\" \"\$ONLOOKER_EVENTS_LOG\"
  "
  [ "$output" = "${elsewhere}/logs/hook-health.jsonl|${elsewhere}/logs/onlooker-events.jsonl" ]
}

# The isolation guard. If a derived path ever escaped the temp home, tests would
# write into the developer's real ~/.onlooker without anything failing.
@test "no derived path escapes the temp home after setup_test_env" {
  [[ "$ONLOOKER_HOOK_HEALTH_LOG" == "$ONLOOKER_DIR"/* ]] || return 1
  [[ "$ONLOOKER_EVENTS_LOG" == "$ONLOOKER_DIR"/* ]] || return 1
  [[ "$ONLOOKER_SESSION_TRACKERS_DIR" == "$ONLOOKER_DIR"/* ]]
}

# ecosystem-449.12. Claude Code exports CLAUDE_CONFIG_DIR (here
# ~/.claude-personal) and does NOT export CLAUDE_HOME. The substrate defaulted
# straight to $HOME/.claude and never consulted CLAUDE_CONFIG_DIR, so on any
# install that relocates the config directory, CLAUDE_HOME pointed at a
# directory Claude Code does not use. Its one consumer, memory-recall-tracker,
# then found no memory store and exited 0 reporting success.
@test "CLAUDE_HOME falls back to CLAUDE_CONFIG_DIR before \$HOME/.claude" {
  run bash -c "
    unset CLAUDE_HOME
    export CLAUDE_CONFIG_DIR='${BATS_TEST_TMPDIR}/relocated'
    source '${REPO_ROOT}/scripts/lib/validate-path.sh'
    printf '%s' \"\$CLAUDE_HOME\"
  "
  [ "$output" = "${BATS_TEST_TMPDIR}/relocated" ]
}

@test "an explicit CLAUDE_HOME still wins over CLAUDE_CONFIG_DIR" {
  run bash -c "
    export CLAUDE_HOME='${BATS_TEST_TMPDIR}/explicit'
    export CLAUDE_CONFIG_DIR='${BATS_TEST_TMPDIR}/relocated'
    source '${REPO_ROOT}/scripts/lib/validate-path.sh'
    printf '%s' \"\$CLAUDE_HOME\"
  "
  [ "$output" = "${BATS_TEST_TMPDIR}/explicit" ]
}

@test "with neither set, CLAUDE_HOME still defaults under HOME" {
  run bash -c "
    unset CLAUDE_HOME CLAUDE_CONFIG_DIR
    export HOME='${BATS_TEST_TMPDIR}/plainhome'
    source '${REPO_ROOT}/scripts/lib/validate-path.sh'
    printf '%s' \"\$CLAUDE_HOME\"
  "
  [ "$output" = "${BATS_TEST_TMPDIR}/plainhome/.claude" ]
}

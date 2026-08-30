#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/scribe"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  START_HOOK="${PLUGIN_ROOT}/scripts/hooks/scribe-session-start.sh"
  CAPTURE_HOOK="${PLUGIN_ROOT}/scripts/hooks/scribe-capture.sh"
  SESSION_DIR="${ONLOOKER_DIR}/scribe/sessions"
}

_start_input() {
  jq -cn --arg cwd "$BATS_TEST_TMPDIR" --arg sid "sess-alpha" \
    '{cwd: $cwd, session_id: $sid, hook_event_name: "SessionStart"}'
}

_capture_input() {
  jq -cn --arg cwd "$BATS_TEST_TMPDIR" --arg sid "sess-alpha" --arg p "why is the gate failing" \
    '{cwd: $cwd, session_id: $sid, prompt: $p, hook_event_name: "UserPromptSubmit"}'
}

@test "session start creates no state file" {
  run bash -c "printf '%s' '$(_start_input)' | '$START_HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "${SESSION_DIR}/sess-alpha.json" ]
}

@test "session start still creates the sessions directory" {
  run bash -c "printf '%s' '$(_start_input)' | '$START_HOOK'"
  [ "$status" -eq 0 ]
  [ -d "$SESSION_DIR" ]
}

@test "capture creates the state file with a payload on first prompt" {
  run bash -c "printf '%s' '$(_start_input)' | '$START_HOOK'"
  [ "$status" -eq 0 ] || return 1
  run bash -c "printf '%s' '$(_capture_input)' | '$CAPTURE_HOOK'"
  [ "$status" -eq 0 ] || return 1
  [ -f "${SESSION_DIR}/sess-alpha.json" ] || return 1
  run jq -r '.captured_prompt' "${SESSION_DIR}/sess-alpha.json"
  [ "$output" = "why is the gate failing" ]
}

@test "capture without a prior session start still creates the state file" {
  run bash -c "printf '%s' '$(_capture_input)' | '$CAPTURE_HOOK'"
  [ "$status" -eq 0 ] || return 1
  run jq -r '.captured_prompt' "${SESSION_DIR}/sess-alpha.json"
  [ "$output" = "why is the gate failing" ]
}

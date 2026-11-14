#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/warden"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
  source "${PLUGIN_ROOT}/scripts/lib/warden-events.sh"

  export ONLOOKER_TEST_REPORT_DIR="${BATS_TEST_TMPDIR}/report"
  mkdir -p "$ONLOOKER_TEST_REPORT_DIR"
  REPORT="${ONLOOKER_TEST_REPORT_DIR}/emissions.jsonl"
}

_valid_payload() {
  jq -cn '{source_type:"web_fetch", threat_type:"prompt_injection", confidence:0.5}'
}

# Positive control. Without this, the opt-out test below could pass because
# nothing writes a report at all, rather than because the helper suppressed it.
@test "a normal emission does write a report line" {
  run warden_emit_event "warden.threat.detected" "$(_valid_payload)"
  [ "$status" -eq 0 ] || return 1
  [ -s "$REPORT" ]
}

@test "expect_emission_rejected keeps a deliberate rejection out of the report" {
  expect_emission_rejected warden_emit_event "warden.bogus.event" "$(_valid_payload)"
  [ "$status" -ne 0 ] || return 1
  [ ! -f "$REPORT" ]
}

@test "expect_emission_rejected restores the report dir afterward" {
  expect_emission_rejected warden_emit_event "warden.bogus.event" "$(_valid_payload)"
  [ "$ONLOOKER_TEST_REPORT_DIR" = "${BATS_TEST_TMPDIR}/report" ] || return 1
  run warden_emit_event "warden.threat.detected" "$(_valid_payload)"
  [ "$status" -eq 0 ] || return 1
  [ -s "$REPORT" ]
}

# The emitter validates only under ONLOOKER_VALIDATE=1, which the suite runner
# sets and bare `bats` does not. A rejection test must assert a rejection
# however the file is run, so the helper turns validation on itself (ONL-205).
@test "expect_emission_rejected validates when the environment does not" {
  unset ONLOOKER_VALIDATE
  expect_emission_rejected warden_emit_event "warden.bogus.event" "$(_valid_payload)"
  [ "$status" -ne 0 ]
}

@test "expect_emission_rejected leaves ONLOOKER_VALIDATE as it found it" {
  unset ONLOOKER_VALIDATE
  expect_emission_rejected warden_emit_event "warden.bogus.event" "$(_valid_payload)"
  [ -z "${ONLOOKER_VALIDATE+set}" ] || return 1

  export ONLOOKER_VALIDATE=0
  expect_emission_rejected warden_emit_event "warden.bogus.event" "$(_valid_payload)"
  [ "$ONLOOKER_VALIDATE" = "0" ]
}

#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/counsel"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-reader.sh"
}

# ---------------------------------------------------------------------------
# counsel_count_events
# ---------------------------------------------------------------------------

@test "count_events returns 0 for empty input" {
  run counsel_count_events ""
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "count_events counts non-blank lines" {
  local text
  text=$(printf '%s\n%s\n%s\n' '{"type":"a"}' '{"type":"b"}' '{"type":"c"}')
  run counsel_count_events "$text"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

# ---------------------------------------------------------------------------
# counsel_sources_from_events
# ---------------------------------------------------------------------------

@test "sources_from_events returns onlooker_events for unknown types" {
  local text='{"type":"scribe.distill.complete"}'
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  [[ "$output" == *"onlooker_events"* ]]
}

@test "sources_from_events detects tribunal events" {
  local text='{"type":"tribunal.gate.blocked"}'
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tribunal_verdicts"* ]]
}

@test "sources_from_events detects echo events" {
  local text='{"type":"echo.regression.detected"}'
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  [[ "$output" == *"echo_regressions"* ]]
}

@test "sources_from_events returns onlooker_events for empty input" {
  run counsel_sources_from_events ""
  [ "$status" -eq 0 ]
  [ "$output" = '["onlooker_events"]' ]
}

# ---------------------------------------------------------------------------
# counsel_read_events — file-based
# ---------------------------------------------------------------------------

@test "read_events returns empty when log does not exist" {
  export ONLOOKER_EVENTS_LOG="${BATS_TEST_TMPDIR}/no-log.jsonl"
  run counsel_read_events "30" "60000"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "read_events returns empty for empty log" {
  local log="${BATS_TEST_TMPDIR}/empty-log.jsonl"
  touch "$log"
  export ONLOOKER_EVENTS_LOG="$log"
  run counsel_read_events "30" "60000"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "read_events filters events within lookback window" {
  local log="${BATS_TEST_TMPDIR}/events.jsonl"
  # Use a timestamp far in the future to ensure it passes any lookback filter.
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="2099-01-01T00:00:00Z"
  printf '%s\n' \
    "{\"event_type\":\"scribe.distill.complete\",\"timestamp\":\"${ts}\",\"session_id\":\"s1\",\"payload\":{}}" \
    > "$log"
  export ONLOOKER_EVENTS_LOG="$log"
  run counsel_read_events "30" "60000"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scribe.distill.complete"* ]]
}

@test "read_events output is JSONL-shaped: one object per line" {
  local log="${BATS_TEST_TMPDIR}/multi-events.jsonl"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="2099-01-01T00:00:00Z"
  printf '%s\n' \
    "{\"event_type\":\"tribunal.gate.blocked\",\"timestamp\":\"${ts}\",\"session_id\":\"s1\",\"payload\":{}}" \
    "{\"event_type\":\"echo.regression.detected\",\"timestamp\":\"${ts}\",\"session_id\":\"s2\",\"payload\":{}}" \
    "{\"event_type\":\"scribe.distill.complete\",\"timestamp\":\"${ts}\",\"session_id\":\"s3\",\"payload\":{}}" \
    > "$log"
  export ONLOOKER_EVENTS_LOG="$log"

  local events
  events=$(counsel_read_events "30" "60000")

  # count_events must see exactly 3 records, not inflated by pretty-printing.
  run counsel_count_events "$events"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "read_events output preserves source types for sources_from_events" {
  local log="${BATS_TEST_TMPDIR}/source-events.jsonl"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="2099-01-01T00:00:00Z"
  printf '%s\n' \
    "{\"event_type\":\"tribunal.gate.blocked\",\"timestamp\":\"${ts}\",\"session_id\":\"s1\",\"payload\":{}}" \
    > "$log"
  export ONLOOKER_EVENTS_LOG="$log"

  local events
  events=$(counsel_read_events "30" "60000")

  run counsel_sources_from_events "$events"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tribunal_verdicts"* ]]
}

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

@test "sources_from_events buckets a substrate type generically" {
  # session/tool/skill/task are the substrate's own, not a plugin's, and
  # onlooker_events is the honest bucket for them.
  local text='{"type":"session.start"}'
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  [ "$output" = '["onlooker_events"]' ]
}

@test "sources_from_events buckets a gate" {
  local text='{"type":"tribunal.gate.blocked"}'
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  [ "$output" = '["gate_blocks"]' ]
}

@test "sources_from_events buckets compass with the other gates" {
  # The motivating case. compass is the most behaviorally aggressive gate in
  # the set and used to fall through to onlooker_events, so a brief could not
  # tell a compass block from an inspector failure.
  local text='{"type":"compass.check.failed"}'
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  [ "$output" = '["gate_blocks"]' ]
}

@test "sources_from_events buckets echo as verification, not its own source" {
  local text='{"type":"echo.regression.detected"}'
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  [ "$output" = '["verification"]' ]
}

@test "sources_from_events emits no retired value" {
  # The six values schema 3.0.0 removed. Emitting one now fails validation and
  # drops the event, which is how the old mapping broke under that release.
  local text
  text=$(printf '%s\n' \
    '{"type":"tribunal.gate.blocked"}' \
    '{"type":"echo.regression.detected"}' \
    '{"type":"warden.threat.detected"}' \
    '{"type":"compass.check.failed"}')
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  local retired
  for retired in tribunal_verdicts echo_regressions warden_audit \
                 sentinel_audit oracle_calibrations meridian_reliance; do
    [[ "$output" != *"$retired"* ]] || return 1
  done
  [ "$output" = '["gate_blocks","verification"]' ]
}

@test "sources_from_events dedupes and sorts across a mixed batch" {
  local text
  text=$(printf '%s\n' \
    '{"type":"compass.check.failed"}' \
    '{"type":"warden.gate.blocked"}' \
    '{"type":"bursar.session.recorded"}' \
    '{"type":"inspector.check.failed"}' \
    '{"type":"tool.file.edit"}')
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  # compass+warden collapse to one gate_blocks entry.
  [ "$output" = '["cost","gate_blocks","onlooker_events","verification"]' ]
}

@test "sources_from_events survives a line truncated mid-JSON" {
  # counsel_read_events cuts its summary at chars_max, so the final line is
  # routinely partial. One unparsable line must not empty the whole array.
  local text
  text=$(printf '%s\n%s' \
    '{"type":"compass.check.failed"}' \
    '{"type":"inspector.check')
  run counsel_sources_from_events "$text"
  [ "$status" -eq 0 ]
  [ "$output" = '["gate_blocks"]' ]
}

# THE DONE-WHEN GUARD. Every shipped plugin that puts events on the bus must
# map to a named bucket, so adding a plugin and forgetting counsel is a test
# failure rather than a brief that silently cannot see it.
@test "no shipped plugin's prefix falls through to onlooker_events" {
  # Deliberately generic, with reasons:
  #   counsel  - its own brief events are not a signal the brief consults
  #              ABOUT the agent; a brief reasoning over its own prior briefs
  #              is not a source class.
  local -r deliberately_generic=" counsel "

  local plugin missing=""
  for plugin in "${REPO_ROOT}"/plugins/*/; do
    plugin=$(basename "$plugin")
    [[ "$deliberately_generic" == *" $plugin "* ]] && continue

    local got
    got=$(counsel_sources_from_events "{\"type\":\"${plugin}.some.event\"}")
    [[ "$got" == '["onlooker_events"]' ]] && missing="${missing}${plugin} "
  done

  [ -z "$missing" ] || {
    printf 'plugins falling through to the generic bucket: %s\n' "$missing" >&2
    return 1
  }
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

@test "read_events survives caller pipefail when output exceeds chars_max" {
  # Regression: head -c closes the pipe once chars_max bytes arrive, sending jq
  # SIGPIPE. Under the caller's `set -o pipefail` (as the hook and skill run),
  # the reader must still return the truncated output, not discard everything.
  local log="${BATS_TEST_TMPDIR}/big-events.jsonl"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="2099-01-01T00:00:00Z"
  : > "$log"
  local i
  for ((i = 0; i < 60; i++)); do
    printf '%s\n' \
      "{\"event_type\":\"tribunal.gate.blocked\",\"timestamp\":\"${ts}\",\"session_id\":\"s${i}\",\"payload\":{\"k\":\"vvvvvvvvvvvvvvvvvvvvvvvvvvvvvv\"}}" \
      >> "$log"
  done
  export ONLOOKER_EVENTS_LOG="$log"

  # Tiny cap so head closes the pipe after the first event or two.
  local out
  set -o pipefail
  out=$(counsel_read_events "30" "200")
  set +o pipefail

  [ -n "$out" ]
  run counsel_count_events "$out"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
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
  [[ "$output" == *"gate_blocks"* ]]
}

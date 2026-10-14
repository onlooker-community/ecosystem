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

# ---------------------------------------------------------------------------
# Window coverage (ONL-165)
#
# The brief used to see 124 of the 93,731 events in its own 30-day window -
# 0.132%, and the OLDEST contiguous slice, because the pipeline ended in
# `head -c`. A weekly coaching brief that structurally cannot see recent
# activity is describing the wrong period.
#
# Two pieces answer it: a summary that covers the WHOLE window in a few KB,
# and a sample that takes the RECENT end of it.
# ---------------------------------------------------------------------------

# A log of $1 events spread one hour apart, oldest first, all inside the
# lookback window. $2 prefixes the event type so a test can tell them apart.
_seed_spread_log() {
  local count="$1" type="$2" log="${BATS_TEST_TMPDIR}/spread.jsonl"
  : > "$log"
  local i ts
  for ((i = 0; i < count; i++)); do
    # Recent half gets a distinct type so the sample's contents are checkable.
    ts=$(relative_iso_days_ago "$(( (count - i) / 24 + 1 ))")
    printf '{"event_type":"%s","timestamp":"%s","session_id":"s%d","plugin":"p","payload":{"filler":"%s"}}\n' \
      "$type" "$ts" "$i" "$(printf 'x%.0s' {1..200})" >> "$log"
  done
  printf '%s' "$log"
}

@test "window_summary counts every event in the window, not a truncated slice" {
  local log
  log=$(_seed_spread_log 400 "tool.file.read")
  export ONLOOKER_EVENTS_LOG="$log"

  local summary
  summary=$(counsel_window_summary "30")

  # All 400, where the old reader would have shown a few dozen.
  [ "$(printf '%s' "$summary" | jq -r '.window.events')" = "400" ]
  [ "$(printf '%s' "$summary" | jq -r '.by_type["tool.file.read"]')" = "400" ]
}

@test "window_summary stays small as the window grows" {
  # The property that makes full coverage affordable: the summary is bounded by
  # the number of distinct types and days, not by the event count.
  local log
  log=$(_seed_spread_log 400 "tool.file.read")
  export ONLOOKER_EVENTS_LOG="$log"

  local summary
  summary=$(counsel_window_summary "30")
  [ "$(printf '%s' "$summary" | jq -r '.window.events')" = "400" ]
  # 400 events described in well under the old 60,000-char budget.
  [ "$(printf '%s' "$summary" | wc -c)" -lt 4000 ]
}

@test "window_summary reports distinct sessions" {
  local log
  log=$(_seed_spread_log 50 "tool.file.read")
  export ONLOOKER_EVENTS_LOG="$log"

  local summary
  summary=$(counsel_window_summary "30")
  [ "$(printf '%s' "$summary" | jq -r '.window.sessions')" = "50" ]
}

@test "window_summary is well-formed on an empty or missing log" {
  export ONLOOKER_EVENTS_LOG="${BATS_TEST_TMPDIR}/absent.jsonl"
  local summary
  summary=$(counsel_window_summary "30")
  [ "$(printf '%s' "$summary" | jq -r '.window.events')" = "0" ]
  printf '%s' "$summary" | jq -e '.by_type == {} and .by_day == {}' >/dev/null
}

# THE BUG ITSELF. With a cap that admits only a few events, the sample must
# hold the NEWEST, not the oldest.
@test "read_events samples the recent end of the window, not the oldest" {
  local log="${BATS_TEST_TMPDIR}/ends.jsonl"
  : > "$log"
  local i
  for ((i = 0; i < 60; i++)); do
    printf '{"event_type":"old.event.type","timestamp":"%s","session_id":"o%d","plugin":"p","payload":{}}\n' \
      "$(relative_iso_days_ago 20)" "$i" >> "$log"
  done
  for ((i = 0; i < 5; i++)); do
    printf '{"event_type":"new.event.type","timestamp":"%s","session_id":"n%d","plugin":"p","payload":{}}\n' \
      "$(relative_iso_days_ago 1)" "$i" >> "$log"
  done
  export ONLOOKER_EVENTS_LOG="$log"

  # A cap that cannot hold all 65.
  local events
  events=$(counsel_read_events "30" "600")

  # Every recent event survives; the OLDEST do not. Asserted on session ids
  # rather than on the absence of old.event.type altogether: the recent end of
  # a 65-event log legitimately includes the last few old events once the
  # budget has room for more lines than there are new ones. The property that
  # matters is which END is kept, and `o0` is the event the old `head -c`
  # would have kept first.
  [[ "$events" == *'"n4"'* ]] || return 1
  [[ "$events" == *'"n0"'* ]] || return 1
  [[ "$events" != *'"o0"'* ]] || return 1
  [[ "$events" != *'"o1"'* ]] || return 1
}

@test "read_events drops payload from the sample" {
  # Payloads were ~480 bytes an event, which is why only 124 fit. They are also
  # the one thing the hosted summarizer refuses to read at all, so keeping them
  # out of an LLM prompt narrows exposure as well as cost.
  local log="${BATS_TEST_TMPDIR}/payload.jsonl"
  printf '{"event_type":"tool.file.read","timestamp":"%s","session_id":"s1","plugin":"p","payload":{"secret":"do-not-send"}}\n' \
    "$(relative_iso_days_ago 1)" > "$log"
  export ONLOOKER_EVENTS_LOG="$log"

  local events
  events=$(counsel_read_events "30" "60000")

  [[ "$events" == *"tool.file.read"* ]] || return 1
  [[ "$events" != *"do-not-send"* ]] || return 1
  [[ "$events" != *"payload"* ]] || return 1
}

@test "read_events fits far more events in the same budget than before" {
  # Dropping payload is what buys the coverage: the same 60,000 chars that
  # held 124 payload-carrying events holds hundreds of envelopes.
  local log
  log=$(_seed_spread_log 400 "tool.file.read")
  export ONLOOKER_EVENTS_LOG="$log"

  local events
  events=$(counsel_read_events "30" "60000")
  [ "$(counsel_count_events "$events")" -ge 300 ]
}

@test "read_events still honors chars_max" {
  local log
  log=$(_seed_spread_log 400 "tool.file.read")
  export ONLOOKER_EVENTS_LOG="$log"

  local events
  events=$(counsel_read_events "30" "2000")
  [ "$(printf '%s' "$events" | wc -c)" -le 2000 ]
  # And still returns something usable rather than collapsing to empty.
  [ "$(counsel_count_events "$events")" -ge 1 ]
}

@test "sources_from_summary covers every type in the window, not just the sample" {
  # The reason sources move off the sample: a bounded sample can miss a whole
  # plugin that the window contains, and the brief would then under-report what
  # it drew on. The summary sees all of it.
  local log="${BATS_TEST_TMPDIR}/sources.jsonl"
  printf '%s\n' \
    "{\"event_type\":\"compass.check.failed\",\"timestamp\":\"$(relative_iso_days_ago 20)\",\"session_id\":\"s1\",\"payload\":{}}" \
    "{\"event_type\":\"bursar.session.recorded\",\"timestamp\":\"$(relative_iso_days_ago 19)\",\"session_id\":\"s2\",\"payload\":{}}" \
    "{\"event_type\":\"tool.file.read\",\"timestamp\":\"$(relative_iso_days_ago 1)\",\"session_id\":\"s3\",\"payload\":{}}" \
    > "$log"
  export ONLOOKER_EVENTS_LOG="$log"

  local summary
  summary=$(counsel_window_summary "30")
  run counsel_sources_from_summary "$summary"
  [ "$status" -eq 0 ]
  # compass and bursar are OLD here; a recent-end sample would miss both.
  [ "$output" = '["cost","gate_blocks","onlooker_events"]' ]
}

@test "sources_from_summary falls back to the generic bucket on junk" {
  run counsel_sources_from_summary "not json"
  [ "$status" -eq 0 ]
  [ "$output" = '["onlooker_events"]' ]
}

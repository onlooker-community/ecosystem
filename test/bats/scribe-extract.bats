#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/scribe"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-extract.sh"
}

# ---------------------------------------------------------------------------
# scribe_count_turns
# ---------------------------------------------------------------------------

@test "count_turns returns 0 for missing file" {
  run scribe_count_turns "/nonexistent/path.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "count_turns returns 0 for empty file" {
  local f="${BATS_TEST_TMPDIR}/empty.jsonl"
  touch "$f"
  run scribe_count_turns "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "count_turns counts only user-role entries" {
  local f="${BATS_TEST_TMPDIR}/transcript.jsonl"
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"hello"}}' \
    '{"type":"assistant","message":{"role":"assistant","content":"hi"}}' \
    '{"type":"user","message":{"role":"user","content":"thanks"}}' \
    '{"type":"assistant","message":{"role":"assistant","content":"sure"}}' \
    > "$f"
  run scribe_count_turns "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "count_turns skips blank lines" {
  local f="${BATS_TEST_TMPDIR}/sparse.jsonl"
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"a"}}' \
    '' \
    '{"type":"user","message":{"role":"user","content":"b"}}' \
    > "$f"
  run scribe_count_turns "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# min_turns gate (via scribe_distill return code)
# ---------------------------------------------------------------------------

@test "scribe_distill exits 2 when transcript has fewer turns than min_turns" {
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-events.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-project-key.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-distill.sh"

  # Load config so min_turns is available (default: 3).
  scribe_config_load ""

  # Transcript with only 1 user turn — below default min_turns of 3.
  local f="${BATS_TEST_TMPDIR}/short.jsonl"
  printf '%s\n' \
    '{"role":"user","content":"hey"}' \
    '{"role":"assistant","content":"yo"}' \
    > "$f"

  run scribe_distill "test-session-id" "${BATS_TEST_TMPDIR}" "$f"
  [ "$status" -eq 2 ]
}

@test "scribe_distill min_turns skip produces no stderr output" {
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-events.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-project-key.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-distill.sh"

  scribe_config_load ""

  local f="${BATS_TEST_TMPDIR}/short2.jsonl"
  printf '%s\n' '{"role":"user","content":"hi"}' > "$f"

  # Run in a subshell capturing stderr separately.
  local stderr_out
  stderr_out=$(scribe_distill "test-sid" "${BATS_TEST_TMPDIR}" "$f" 2>&1 >/dev/null) || true
  [ -z "$stderr_out" ]
}

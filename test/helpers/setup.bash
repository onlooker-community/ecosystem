#!/usr/bin/env bash
# Shared setup for Onlooker ecosystem bats tests.

# Repo root: test/helpers -> test -> repo
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# BATS_TEST_TMPDIR may be unset during setup_file on some runners; ensure a temp base.
if [[ -z "${BATS_TEST_TMPDIR:-}" ]]; then
  export BATS_TEST_TMPDIR="${TMPDIR:-/tmp}/onlooker-bats-${BATS_SUITE_TEST_NUMBER:-$$}"
  mkdir -p "$BATS_TEST_TMPDIR"
fi

# Isolate all filesystem side effects under BATS_TEST_TMPDIR.
setup_test_env() {
  export TEST_HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$TEST_HOME"

  export HOME="$TEST_HOME"
  export ONLOOKER_DIR="${TEST_HOME}/.onlooker"
  export CLAUDE_HOME="${TEST_HOME}/.claude"
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"

  # Sever git from the developer's global config. Otherwise XDG_CONFIG_HOME
  # (which is exported by the parent shell and not affected by reassigning
  # HOME) leaks `commit.gpgsign = true` and the per-test signingkey path
  # into git-driven tests like worktree-tracker, where there's no SSH key
  # in the isolated $TEST_HOME and `git worktree add` fails to sign.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null
  unset XDG_CONFIG_HOME

  # validate-path.sh derives these from ONLOOKER_DIR but lets an explicit value
  # win (ecosystem-449.6). Clear them so a value inherited from the developer's
  # shell cannot outlive the temp home we just built — without this, an isolated
  # test could write into the real ~/.onlooker and nothing would fail.
  unset ONLOOKER_SESSION_TRACKERS_DIR ONLOOKER_SESSION_HISTORY_DIR \
        ONLOOKER_SESSION_SUMMARIES_DIR ONLOOKER_COMPACT_TRACKERS_DIR \
        ONLOOKER_METRICS_DIR ONLOOKER_EVENTS_LOG ONLOOKER_HOOK_HEALTH_LOG

  # Same reasoning for the config dir. CLAUDE_HOME is set above so the
  # fallback chain in validate-path.sh short-circuits before reaching this,
  # but a test that unsets CLAUDE_HOME would otherwise inherit the developer's
  # real CLAUDE_CONFIG_DIR and read their actual memory store.
  unset CLAUDE_CONFIG_DIR
}

# Produce an ISO-8601 UTC timestamp offset from "now" by N days into the past.
# Positive N = N days ago, 0 = now, negative N = N days in the future.
#
# Use this for any fixture whose date must fall inside a relative window the
# code computes from "now" (e.g. a "now - lookback_days" scan window). A
# hardcoded ISO date silently ages out of such a window and turns the test
# into a time bomb that passes today and fails on some future date. Always
# date those fixtures relative to now.
#
# Uses python3 (already a hook dependency) for portable date math — `date -d`
# vs `date -v` diverges between GNU and BSD/macOS.
#
# Usage: created_at=$(relative_iso_days_ago 1)   # yesterday, UTC
relative_iso_days_ago() {
  local days="${1:-0}"
  python3 -c '
import datetime, sys
delta = datetime.timedelta(days=int(sys.argv[1]))
now = datetime.datetime.now(datetime.timezone.utc)
print((now - delta).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$days"
}

# Source validate-path.sh with test env vars already set.
load_validate_path() {
  setup_test_env
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/validate-path.sh"

  mkdir -p \
    "$(dirname "$ONLOOKER_EVENTS_LOG")" \
    "$ONLOOKER_SESSION_TRACKERS_DIR" \
    "$ONLOOKER_SESSION_HISTORY_DIR" \
    "$ONLOOKER_SESSION_SUMMARIES_DIR" \
    "$ONLOOKER_COMPACT_TRACKERS_DIR" \
    "$ONLOOKER_METRICS_DIR"
}

# Run a command that is expected to fail schema validation, without recording
# the deliberate rejection in the suite-wide emission report.
#
# The report exists so a payload that drifts from the schema turns CI red. A
# test that deliberately emits an invalid payload would otherwise write a
# valid:false line indistinguishable from real drift, making the gate
# permanently red from intentional tests. Unsetting the report directory for
# the duration keeps the negative test honest — it still asserts the emitter
# rejects — without polluting the gate.
#
# Sets $status and $output exactly as bats' `run` does.
#
# Usage: expect_emission_rejected <command> [args...]
expect_emission_rejected() {
  local saved="${ONLOOKER_TEST_REPORT_DIR:-}"
  unset ONLOOKER_TEST_REPORT_DIR
  run "$@"
  if [ -n "$saved" ]; then
    export ONLOOKER_TEST_REPORT_DIR="$saved"
  fi
}

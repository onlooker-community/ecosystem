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

#!/usr/bin/env bash
# Detached brief synthesis.
#
# counsel's SessionStart hook used to call counsel_generate_brief inline, and
# the evaluator ships timeout: 90. The synthesis_interval_days gate limits how
# OFTEN that happened, not how LONG it took, so roughly once a week a session
# start blocked on an LLM call with a 90-second ceiling (ecosystem-449.19).
#
# The brief is a weekly digest, so deferring it one session costs nothing. The
# hook spawns this script detached and injects whatever brief exists at the
# NEXT session start.
#
# Usage: counsel-refresh.sh <session_id> <cwd> <project_key>
#
# Contract:
#   - Always exits 0. Nothing waits on it.
#   - Single-flight: takes the lock itself and exits quietly if another refresh
#     already holds it.
#   - Output goes to <briefs_dir>/synthesis.log; stdout is never a hook channel.

set -uo pipefail

SESSION_ID="${1:-}"
CWD="${2:-}"
PROJECT_KEY="${3:-}"
[[ -z "$SESSION_ID" || -z "$CWD" || -z "$PROJECT_KEY" ]] && exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Inherited from the hook, but set explicitly: this process outlives its
# parent, and the claude call below must not re-enter counsel's SessionStart
# hook in the nested session (ecosystem-449.23).
export COUNSEL_NESTED=1

# shellcheck source=lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=lib/counsel-config.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-config.sh"
# shellcheck source=lib/counsel-events.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-events.sh"
# shellcheck source=lib/counsel-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-project-key.sh"
# shellcheck source=lib/counsel-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-ulid.sh"
# shellcheck source=lib/counsel-reader.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-reader.sh"
# shellcheck source=lib/counsel-synthesize.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-synthesize.sh"
# shellcheck source=lib/counsel-brief.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-brief.sh"

REPO_ROOT=$(counsel_project_repo_root "$CWD")
counsel_config_load "$REPO_ROOT"

BRIEFS_DIR=$(counsel_project_dir "$PROJECT_KEY") || exit 0
mkdir -p "$BRIEFS_DIR" 2>/dev/null || exit 0
LOCK="${BRIEFS_DIR}/.synthesis.lock"

# The lock is taken HERE rather than in the hook. A parent that acquires and
# then exits leaves a holder pid that is already gone, which the stale-lock
# reclamation correctly treats as abandoned and breaks — handing the lock
# straight to the next session and defeating the single-flight it was meant to
# provide. Timeout 0: if a refresh is already running, this one is redundant.
lock_acquire "$LOCK" 0 || exit 0

# force=1 bypasses the staleness gate. The hook already decided it was stale;
# re-checking here would race with a refresh that just finished.
counsel_generate_brief "$SESSION_ID" "$CWD" force >/dev/null 2>&1 || true

lock_release "$LOCK"
exit 0

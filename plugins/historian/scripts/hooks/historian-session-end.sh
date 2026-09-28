#!/usr/bin/env bash
# Historian SessionEnd indexing launcher.
#
# Launches the indexing pipeline and returns. The pipeline itself lives in
# scripts/run-index.sh — see its header for why it cannot run here.
#
# The short version: a SessionEnd hook that declares no timeout is killed at
# 1500ms. A warm embed costs 51ms, so the budget buys about 29 chunks, and a
# real 8.5MB transcript chunks into 117. A cold model load costs 11.24s and so
# never completes at all. Running inline, every historian.indexing.complete
# with outcome "ok" in the live log indexed exactly 2 chunks — not historian
# working, just the only size that fit — while the larger sessions show up in
# hook-health.jsonl as `terminated` at 1503-1527ms (ONL-123).
#
# Hook contract:
#   - Always exits 0. Never blocks session shutdown.
#   - Decides nothing beyond having a session id. Every reason historian
#     declines to index is emitted by run-index.sh, so that reporting costs
#     the SessionEnd path nothing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "historian-session-end"

INPUT=$(cat 2>/dev/null || true)
hook_health_context "$INPUT"
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""
[[ -z "$CWD" ]] && CWD="$(pwd)"

# A session id is the one thing worth checking here: without it there is
# nothing to attribute an event to, so the child could not report its own
# skip either. Everything else — a missing transcript_path, a path with no
# file at it, a transcript below the minimum — is decided and REPORTED by
# run-index.sh. ONL-121 is still waiting on transcript_path_absent versus
# transcript_file_missing to tell its two halves apart, and moving those
# emits into the child keeps them firing while taking them off this path.
[[ -z "$SESSION_ID" ]] && hook_health_exit 0

# stderr goes to a log rather than /dev/null, which is not a stylistic choice:
# scribe lost a --max-tokens bug to a discarded stderr and produced nothing
# across 13,201 sessions without anyone noticing (ONL-30). Detaching the work
# moves every remaining diagnostic off the terminal, so the one place it can
# still be read has to be a file.
INDEX_LOG="${ONLOOKER_DIR:-${HOME}/.onlooker}/historian/index.log"
mkdir -p "$(dirname "$INDEX_LOG")" 2>/dev/null || true

export HISTORIAN_SESSION_ID="$SESSION_ID"
export HISTORIAN_CWD="$CWD"
export HISTORIAN_TRANSCRIPT="$TRANSCRIPT_PATH"
export ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"

# The lock is deliberately NOT taken here. run-index.sh acquires it, because a
# launcher that acquires and then exits leaves portable-lock a holder pid that
# is already dead, which the next caller reclaims as stale — a lock that
# excludes nothing (ecosystem-hap).
#
# setsid detaches from the controlling terminal so ending the session does not
# SIGHUP the pass mid-flight; nohup alone on macOS, where setsid is absent.
if command -v setsid >/dev/null 2>&1; then
	nohup setsid "${PLUGIN_ROOT}/scripts/run-index.sh" >>"$INDEX_LOG" 2>&1 &
else
	nohup "${PLUGIN_ROOT}/scripts/run-index.sh" >>"$INDEX_LOG" 2>&1 &
fi
disown 2>/dev/null || true

hook_health_exit 0

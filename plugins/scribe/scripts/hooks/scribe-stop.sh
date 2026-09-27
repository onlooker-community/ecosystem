#!/usr/bin/env bash
# Scribe Stop hook — intent distillation.
#
# Fires when the agent session ends. Reads the full session transcript,
# runs a Haiku extraction pass to identify the problem context, decisions,
# tradeoffs, and constraints, then writes a Markdown intent document to
# ~/.onlooker/scribe/<project_key>/<date>-<session>.md.
#
# Skip conditions, all decided in run-distill.sh and all reported as
# scribe.distill.skipped with a reason:
#   - no transcript_path in hook input, or file is unreadable
#   - session has fewer turns than scribe.capture.min_turns
#   - too few new turns since the last pass covered this transcript
#   - a pass for this session is already running
#
# The hook itself skips silently on one thing only: a missing session id,
# which leaves nothing to attribute an event to.
#
# Hook contract:
#   - Always exits 0. Never blocks Stop.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

# Recursion guard — must be first, above hook_health_register, so a nested
# invocation is not measured as a real hook run (ecosystem-449.23).
#
# scribe reaches claude through scribe-extract.sh. The nested session stops,
# firing Stop and re-entering this hook.
[[ "${SCRIBE_NESTED:-}" == "1" ]] && exit 0
export SCRIBE_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "scribe-stop"

# shellcheck source=../lib/scribe-config.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"
# shellcheck source=../lib/scribe-events.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-events.sh"
# shellcheck source=../lib/scribe-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-project-key.sh"
# shellcheck source=../lib/scribe-extract.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-extract.sh"
# shellcheck source=../lib/scribe-distill.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-distill.sh"

INPUT=$(cat)
hook_health_context "$INPUT"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""

export _HOOK_SESSION_ID="$SESSION_ID"

_done() { hook_health_exit 0; }

[[ -z "$SESSION_ID" ]] && _done

scribe_config_load "$CWD"

# No transcript check here, deliberately. run-distill.sh makes that call, so
# that reporting it costs the Stop path nothing — see the note there. The hook
# launches unconditionally and decides nothing beyond having a session id.
#
# Distillation is launched, not awaited. It runs a `claude -p` pass over the
# whole transcript under a 60s timeout, and calling it inline is what made this
# hook contradict the contract at the top of this file: measured on 2026-09-26,
# three of five Stop fires in one session cost 53.6s, 40.9s and 45.1s, against
# 95-253ms for every other Stop hook (ONL-41).
#
# The lock is deliberately NOT taken here. run-distill.sh acquires it, because a
# launcher that acquires and then exits leaves portable-lock a holder pid that is
# already dead, which the next caller reclaims as stale — a lock that excludes
# nothing (ecosystem-hap).
#
# setsid detaches from the controlling terminal so ending the session does not
# SIGHUP the pass mid-flight; nohup alone on macOS, where setsid is absent.
#
# stderr goes to a log rather than /dev/null, which is not a stylistic choice:
# scribe already lost a `--max-tokens` bug to a discarded stderr and produced
# nothing across 13,201 sessions without anyone noticing (ONL-30). Detaching the
# work moves every remaining diagnostic off the terminal, so the one place it can
# still be read has to be a file.
DISTILL_LOG="${ONLOOKER_DIR:-${HOME}/.onlooker}/scribe/distill.log"
mkdir -p "$(dirname "$DISTILL_LOG")" 2>/dev/null || true

export SCRIBE_SESSION_ID="$SESSION_ID"
export SCRIBE_CWD="$CWD"
export SCRIBE_TRANSCRIPT="$TRANSCRIPT_PATH"
export ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"

if command -v setsid >/dev/null 2>&1; then
	nohup setsid "${PLUGIN_ROOT}/scripts/run-distill.sh" >>"$DISTILL_LOG" 2>&1 &
else
	nohup "${PLUGIN_ROOT}/scripts/run-distill.sh" >>"$DISTILL_LOG" 2>&1 &
fi
disown 2>/dev/null || true

_done

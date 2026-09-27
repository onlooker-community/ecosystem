#!/usr/bin/env bash
# run-distill.sh — Scribe's intent distillation, off the Stop path.
#
# Intended to run as a detached background process launched by the Stop hook.
# scribe-stop.sh used to call scribe_distill inline, which contradicted the
# contract in its own header ("Never blocks Stop"): the distillation runs a
# `claude -p` pass over the whole transcript under a 60s timeout. Measured in
# one session on 2026-09-26, Stop fired five times and distilled on three of
# them, at 53.6s, 40.9s and 45.1s, against 95-253ms for every other Stop hook.
#
# Environment (all set by the launching hook):
#   SCRIBE_SESSION_ID     — session whose transcript to distill
#   SCRIBE_CWD            — session cwd, for config and project key resolution
#   SCRIBE_TRANSCRIPT     — transcript path, as the hook received it
#   CLAUDE_PLUGIN_ROOT    — plugin root
#   ONLOOKER_DIR          — state root, inherited so the child writes where the
#                           parent would have
#
# THIS SCRIPT HOLDS ITS OWN LOCK, and the launching hook must not take it
# (ecosystem-hap, learned the hard way by cartographer). portable-lock stamps
# the holder pid at acquire time; a launcher that acquires and then exits within
# milliseconds leaves a holder that is already gone, so the next caller's
# `kill -0` finds it dead, calls the lock stale, and reclaims it — the lock then
# excludes nothing. A launcher's EXIT trap is no better, because backgrounding
# and exiting discards it and nothing ever releases.
#
# Why a lock at all, when inline execution needed none: Stop fires once per
# TURN. Inline, each pass finished before the next Stop could start it. Detached,
# a 40-54s pass and turns closer together than that means two passes writing the
# same <date>-<session>.md and billing two Haiku calls for one artifact.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# shellcheck source=./lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=./lib/scribe-config.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"
# shellcheck source=./lib/scribe-events.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-events.sh"
# shellcheck source=./lib/scribe-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-project-key.sh"
# shellcheck source=./lib/scribe-extract.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-extract.sh"
# shellcheck source=./lib/scribe-distill.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-distill.sh"

SESSION_ID="${SCRIBE_SESSION_ID:-}"
CWD="${SCRIBE_CWD:-}"
TRANSCRIPT_PATH="${SCRIBE_TRANSCRIPT:-}"

[[ -z "$SESSION_ID" ]] && exit 0

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"

# Keyed by session, not by project: two sessions distilling at once write
# different files and must not block each other, while two Stops of the SAME
# session are the collision this exists to prevent.
LOCK_FILE="${ONLOOKER_DIR}/scribe/sessions/${SESSION_ID}.distill.lock"
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true

# Non-blocking: a second Stop declines rather than queueing behind a pass that
# is already covering the same transcript, since waiting would only produce a
# duplicate of the artifact the holder is about to write. stale_after is 0 so it
# matches the timeout, which is the pairing portable-lock warns about — a stale
# window wider than the timeout can never be reached by the acquire loop.
if ! lock_acquire "$LOCK_FILE" 0 0; then
	exit 0
fi
trap 'lock_release "$LOCK_FILE"' EXIT

scribe_config_load "$CWD"

_rc=0
output_path=$(scribe_distill "$SESSION_ID" "$CWD" "$TRANSCRIPT_PATH") || _rc=$?

if [[ $_rc -ne 0 ]]; then
	# rc=2 means below min_turns — a silent skip, not an error.
	if [[ $_rc -ne 2 ]]; then
		printf '%s scribe: distillation failed for session %s (rc=%s)\n' \
			"$(date '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')" \
			"$SESSION_ID" "$_rc" >&2
	fi
	exit 0
fi

[[ -n "$output_path" ]] && printf '%s scribe: intent document written -> %s\n' \
	"$(date '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unknown')" "$output_path" >&2

exit 0

#!/usr/bin/env bash
# Scribe SessionStart hook.
#
# Fires at every session start. Responsibilities:
#   1. Create storage directories.
#
# Deliberately does NOT create the session state file. It used to, with
# captured_prompt and captured_at both null, which meant every session that
# never submitted a prompt left a payload-free file behind — 65% of scribe's
# 37,403 files, 100MB of 4KB blocks holding zero information (ecosystem-449.2).
# scribe-capture.sh creates the file with a real payload on the first prompt,
# and scribe-distill.sh tolerates its absence, so nothing needs the empty one.
#
# Hook contract:
#   - Always exits 0. Never blocks SessionStart.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "scribe-session-start"

# shellcheck source=../lib/scribe-config.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"

INPUT=$(cat)
hook_health_context "$INPUT"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

_done() { exit 0; }

scribe_config_load "$CWD"

export _HOOK_SESSION_ID="$SESSION_ID"

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
SCRIBE_SESSION_DIR="${ONLOOKER_DIR}/scribe/sessions"
mkdir -p "$SCRIBE_SESSION_DIR" 2>/dev/null || true

_done

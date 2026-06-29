#!/usr/bin/env bash
# Warden SessionStart hook.
#
# Fires at every session start. Responsibilities:
#   1. Ensure the session gate directory exists.
#
# A new session starts with the gate OPEN — the gate is session-scoped because
# the threat model is untrusted content ingested into THIS session's context.
# We never carry a closed gate across sessions, and we never auto-create a
# closed lock here.
#
# Hook contract:
#   - Always exits 0. Never blocks SessionStart.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/warden-config.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-config.sh"
# shellcheck source=../lib/warden-gate-state.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-gate-state.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

_done() { exit 0; }

warden_config_load "$CWD"

[[ -z "$SESSION_ID" ]] && {
	printf 'warden-session-start: no session_id in hook input\n' >&2
	_done
}

GATE_DIR=$(warden_gate_dir "$SESSION_ID")
mkdir -p "$GATE_DIR" 2>/dev/null || {
	printf 'warden-session-start: failed to create gate dir %s\n' "$GATE_DIR" >&2
	_done
}

_done

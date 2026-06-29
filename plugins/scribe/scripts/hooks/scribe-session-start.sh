#!/usr/bin/env bash
# Scribe SessionStart hook.
#
# Fires at every session start. Responsibilities:
#   1. Create storage directories.
#   2. Initialize session state file:
#      - captured_prompt: null (populated by scribe-capture.sh on first turn)
#      - captured_at: null
#
# Hook contract:
#   - Always exits 0. Never blocks SessionStart.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/scribe-config.sh
source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

_done() { exit 0; }

scribe_config_load "$CWD"

export _HOOK_SESSION_ID="$SESSION_ID"

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
SCRIBE_SESSION_DIR="${ONLOOKER_DIR}/scribe/sessions"
mkdir -p "$SCRIBE_SESSION_DIR" 2>/dev/null || true

[[ -z "$SESSION_ID" ]] && _done

STATE_FILE="${SCRIBE_SESSION_DIR}/${SESSION_ID}.json"

jq -n \
	--arg sid "$SESSION_ID" \
	'{
		session_id: $sid,
		captured_prompt: null,
		captured_at: null
	}' 2>/dev/null > "$STATE_FILE" || {
	printf 'scribe-session-start: failed to write state file %s\n' "$STATE_FILE" >&2
	_done
}

_done

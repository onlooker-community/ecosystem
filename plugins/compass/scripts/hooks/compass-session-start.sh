#!/usr/bin/env bash
# Compass SessionStart hook.
#
# Fires at every session start. Responsibilities:
#   1. Skip silently when compass.enabled is false.
#   2. Create storage directories.
#   3. Initialize session state file:
#      - turn_check_count: 0
#      - cooldown table: empty
#      - circuit_breaker: {state: "closed", consecutive_failures: 0}
#
# Hook contract:
#   - Always exits 0. Never blocks SessionStart.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

_ECOSYSTEM_ROOT="${ONLOOKER_ECOSYSTEM_ROOT:-}"
if [[ -z "$_ECOSYSTEM_ROOT" ]]; then
	_candidate="$(cd "${PLUGIN_ROOT}/../.." 2>/dev/null && pwd)"
	if [[ -f "${_candidate}/scripts/lib/validate-path.sh" ]]; then
		_ECOSYSTEM_ROOT="$_candidate"
	fi
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/compass-config.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-config.sh"
# shellcheck source=../lib/compass-events.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-events.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

_done() { exit 0; }

compass_config_load "$CWD"

if ! compass_config_enabled; then
	_done
fi

export _HOOK_SESSION_ID="$SESSION_ID"

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
COMPASS_STATE_DIR="${ONLOOKER_DIR}/compass/sessions"
mkdir -p "$COMPASS_STATE_DIR" 2>/dev/null || true

if [[ -z "$SESSION_ID" ]]; then
	printf 'compass-session-start: no session_id in hook input\n' >&2
	_done
fi

STATE_FILE="${COMPASS_STATE_DIR}/${SESSION_ID}.json"

jq -n \
	--arg sid "$SESSION_ID" \
	'{
		session_id: $sid,
		turn_check_count: 0,
		cooldown: [],
		circuit_breaker: {
			state: "closed",
			consecutive_failures: 0,
			opened_at: null
		}
	}' 2>/dev/null > "$STATE_FILE" || {
	printf 'compass-session-start: failed to write state file %s\n' "$STATE_FILE" >&2
	_done
}

_done

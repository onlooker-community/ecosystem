#!/usr/bin/env bash
# Governor SessionStart hook.
#
# Fires at every session start. Responsibilities:
#   1. Skip silently when governor.enabled is false.
#   2. Create governance storage directories.
#   3. Sweep stale lock files left by crashed prior sessions.
#   4. Check global-policy.yaml exists (warn if missing, don't block).
#   5. Emit governor.lock.stale_cleared for each stale lock removed.
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

if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/portable-lock.sh"
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/governor-config.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-config.sh"
# shellcheck source=../lib/governor-events.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-events.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""

_done() { exit 0; }

governor_config_load ""

if ! governor_config_enabled; then
	_done
fi

# -----------------------------------------------------------------------
# 1. Ensure storage directories exist.
# -----------------------------------------------------------------------
ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
GOVERNANCE_DIR="${ONLOOKER_DIR}/governance"
LEDGER_DIR="${GOVERNANCE_DIR}/ledgers"
mkdir -p "$LEDGER_DIR" 2>/dev/null || true

# -----------------------------------------------------------------------
# 2. Sweep stale lock directories.
#    A lock dir is "stale" if it is older than 60 seconds.
#    We only clean .lock.d directories under the ledgers directory.
# -----------------------------------------------------------------------
STALE_AGE=60

if [[ -d "$LEDGER_DIR" ]]; then
	while IFS= read -r -d '' lockdir; do
		[[ -d "$lockdir" ]] || continue

		lock_age=0
		if command -v stat >/dev/null 2>&1; then
			# macOS stat: -f %m; GNU stat: -c %Y
			mtime=$(stat -f '%m' "$lockdir" 2>/dev/null) \
				|| mtime=$(stat -c '%Y' "$lockdir" 2>/dev/null) \
				|| mtime=0
			now=$(date +%s 2>/dev/null) || now=0
			lock_age=$(( now - mtime ))
		fi

		if (( lock_age >= STALE_AGE )); then
			rmdir "$lockdir" 2>/dev/null || true
			cleared_payload=$(jq -n \
				--arg lp "$lockdir" \
				--argjson age "$lock_age" \
				'{
					lock_path: $lp,
					lock_age_seconds: $age,
					pid_verified_dead: false
				}' 2>/dev/null) || cleared_payload="{}"
			governor_emit_event "governor.lock.stale_cleared" "$cleared_payload" || true
		fi
	done < <(find "$LEDGER_DIR" -maxdepth 2 -name '*.lock.d' -print0 2>/dev/null)
fi

# -----------------------------------------------------------------------
# 3. Global policy file check (advisory only).
# -----------------------------------------------------------------------
POLICY_PATH=$(governor_config_get '.governor.global_policy_path')
POLICY_PATH="${POLICY_PATH/#\~/$HOME}"

if [[ -n "$POLICY_PATH" && ! -f "$POLICY_PATH" ]]; then
	printf 'governor: global-policy.yaml not found at %s — running without global ceiling\n' \
		"$POLICY_PATH" >&2
fi

_done

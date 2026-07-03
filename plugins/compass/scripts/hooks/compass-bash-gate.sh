#!/usr/bin/env bash
# Compass PreToolUse hook — Bash write-pattern filter.
#
# Fires before every Bash tool call. Exits 0 immediately if the command
# doesn't match a write pattern. When a write pattern is detected,
# delegates to the shared compass-gate.sh pipeline.
#
# Hook contract (Claude Code PreToolUse protocol):
#   - Always exits 0.
#   - To block: compass_run_gate writes {"decision":"block","reason":"..."} to stdout.
#   - To allow: nothing written to stdout.
#   - Errors are written to stderr only.

set -uo pipefail

# Recursion guard — must be first.
# When the evaluator shells out to `claude -p`, that subprocess can
# trigger its own Bash hooks, which would re-enter Compass.
[[ "${COMPASS_NESTED:-}" == "1" ]] && exit 0
export COMPASS_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/compass-config.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-config.sh"
# shellcheck source=../lib/compass-events.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-events.sh"
# shellcheck source=../lib/compass-sanitizer.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-sanitizer.sh"
# shellcheck source=../lib/compass-transcript.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-transcript.sh"
# shellcheck source=../lib/compass-evaluator.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-evaluator.sh"
# shellcheck source=../lib/compass-gate.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-gate.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || COMMAND=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""

export _HOOK_SESSION_ID="$SESSION_ID"

compass_config_load "$CWD"

[[ -z "$COMMAND" ]] && exit 0

# -----------------------------------------------------------------------
# Write-pattern detection — exit 0 immediately for read-only commands.
# -----------------------------------------------------------------------
_is_write_command() {
	local cmd="$1"

	# Redirect operators: >, >>, 2>, &>, |&
	if printf '%s' "$cmd" | grep -qE '(^|[[:space:]]|;|\|)(>>?|2>|&>|\|&)' 2>/dev/null; then
		return 0
	fi

	local write_patterns=(
		'\brm\b'
		'\bmv\b'
		'\bcp\b'
		'\bgit\s+commit\b'
		'\bgit\s+push\b'
		'\bsed\s+.*-i\b'
		'\bsed\s+-i\b'
		'\bawk\s+.*-i\b'
		'\bperl\s+.*-i\b'
		'\bdd\b'
		'\btruncate\b'
		'\btee\b'
		'\binstall\b'
		'\bchmod\b'
		'\bchown\b'
		'\bmkdir\b'
		'\btouch\b'
	)

	local pat
	for pat in "${write_patterns[@]}"; do
		if printf '%s' "$cmd" | grep -qE "$pat" 2>/dev/null; then
			return 0
		fi
	done

	return 1
}

if ! _is_write_command "$COMMAND"; then
	exit 0
fi

compass_run_gate "Bash" "" "bash_write" "$COMMAND" "$SESSION_ID" "$CWD" "$TRANSCRIPT_PATH"
exit $?

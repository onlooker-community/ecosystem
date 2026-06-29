#!/usr/bin/env bash
# Compass PostToolUse hook — cooldown recorder.
#
# Fires after a successful Write, Edit, or MultiEdit. Records the file
# path's dir+stem identity and a timestamp to the session state so the
# trigger gate can skip re-checking the same file within cooldown.seconds.
#
# Hook contract:
#   - Always exits 0. Never blocks PostToolUse.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

# Recursion guard — must be first.
# A nested `claude -p` Write would otherwise re-enter the cooldown writer.
[[ "${COMPASS_NESTED:-}" == "1" ]] && exit 0
export COMPASS_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/compass-config.sh
source "${PLUGIN_ROOT}/scripts/lib/compass-config.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

_done() { exit 0; }

compass_config_load "$CWD"

[[ -z "$SESSION_ID" ]] && _done

# Extract the file path from the tool output.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL_NAME=""
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // ""' 2>/dev/null) || FILE_PATH=""

# MultiEdit: record all target paths.
if [[ "$TOOL_NAME" == "MultiEdit" ]]; then
	MULTI_PATHS=$(printf '%s' "$INPUT" \
		| jq -r '.tool_input.edits[]?.file_path // empty' 2>/dev/null) || MULTI_PATHS=""
fi

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
STATE_FILE="${ONLOOKER_DIR}/compass/sessions/${SESSION_ID}.json"

[[ -f "$STATE_FILE" ]] || _done

# Compute dir+stem identity for a file path.
_dir_plus_stem() {
	local path="$1"
	[[ -z "$path" ]] && return 1
	local dir base stem
	dir=$(dirname "$path" 2>/dev/null) || dir="."
	base=$(basename "$path" 2>/dev/null) || base="$path"
	# Stem = everything before the first dot in the basename.
	stem="${base%%.*}"
	[[ -z "$stem" ]] && stem="$base"
	printf '%s/%s' "$dir" "$stem"
}

_record_path() {
	local path="$1"
	[[ -z "$path" ]] && return

	local identity
	identity=$(_dir_plus_stem "$path") || return

	local now
	now=$(date +%s 2>/dev/null) || now=0

	local updated
	updated=$(jq \
		--arg identity "$identity" \
		--arg path "$path" \
		--argjson ts "$now" \
		'.cooldown = (
			[.cooldown[] | select(.identity != $identity)]
			+ [{"identity": $identity, "path": $path, "ts": $ts}]
		)' "$STATE_FILE" 2>/dev/null) || return

	[[ -n "$updated" ]] && printf '%s' "$updated" > "$STATE_FILE"
}

if [[ -n "$FILE_PATH" ]]; then
	_record_path "$FILE_PATH"
fi

if [[ "$TOOL_NAME" == "MultiEdit" && -n "${MULTI_PATHS:-}" ]]; then
	while IFS= read -r p; do
		[[ -n "$p" ]] && _record_path "$p"
	done <<< "$MULTI_PATHS"
fi

_done

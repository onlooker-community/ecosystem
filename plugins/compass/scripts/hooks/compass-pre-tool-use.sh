#!/usr/bin/env bash
# Compass PreToolUse hook — main alignment gate for Write, Edit, MultiEdit.
#
# Fires before write-class tool calls. Resolves the file path from the
# tool input and delegates to the shared compass-gate.sh pipeline.
#
# Hook contract (Claude Code PreToolUse protocol):
#   - Always exits 0.
#   - To block: compass_run_gate writes {"decision":"block","reason":"..."} to stdout.
#   - To allow: nothing written to stdout.
#   - Errors are written to stderr only.

set -uo pipefail

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
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL_NAME=""

export _HOOK_SESSION_ID="$SESSION_ID"

compass_config_load "$CWD"

if ! compass_config_enabled; then
	exit 0
fi

# -----------------------------------------------------------------------
# Resolve file path and context from tool input.
# -----------------------------------------------------------------------
FILE_PATH=""
CONTEXT=""
OPERATION=""

case "$TOOL_NAME" in
	Write)
		FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || FILE_PATH=""
		CONTEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null) || CONTEXT=""
		OPERATION="write"
		;;
	Edit)
		FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || FILE_PATH=""
		# Context: the old_string + new_string gives meaningful signal about what's changing.
		_old_str=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // ""' 2>/dev/null) || _old_str=""
		_new_str=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null) || _new_str=""
		CONTEXT="Replacing: ${_old_str} With: ${_new_str}"
		OPERATION="edit"
		;;
	MultiEdit)
		# MultiEdit applies to one file via a top-level file_path; fall back to
		# the first edit's path for any nested shape.
		FILE_PATH=$(printf '%s' "$INPUT" \
			| jq -r '.tool_input.file_path // .tool_input.edits[0].file_path // ""' 2>/dev/null) || FILE_PATH=""
		_edit_count=$(printf '%s' "$INPUT" \
			| jq '.tool_input.edits | length' 2>/dev/null) || _edit_count="?"
		# Combine the top-level path with any per-edit paths, drop blanks/nulls.
		_file_list=$(printf '%s' "$INPUT" \
			| jq -r '([.tool_input.file_path] + [.tool_input.edits[]?.file_path] | map(select(. != null and . != "")) | unique) | join(", ")' 2>/dev/null) \
			|| _file_list=""
		[[ -z "$_file_list" ]] && _file_list="$FILE_PATH"
		# Both blank (a MultiEdit with no resolvable path) — keep the context legible.
		[[ -z "$_file_list" ]] && _file_list="(unknown)"
		CONTEXT="MultiEdit: ${_edit_count} edit(s) across: ${_file_list}"
		OPERATION="multi_edit"
		;;
	*)
		# Unknown tool — allow through; this hook should only fire for known tools.
		exit 0
		;;
esac

compass_run_gate "$TOOL_NAME" "$FILE_PATH" "$OPERATION" "$CONTEXT" "$SESSION_ID" "$CWD"
exit $?

#!/usr/bin/env bash
# inspector-post-write.sh — PostToolUse hook for Write / Edit / MultiEdit.
#
# Runs the project's configured lint and typecheck commands on just the
# touched file. Emits inspector.check.* and inspector.run.completed events.
# Surfaces a compact summary on stdout for the agent's next turn.
# Always exits 0 — inspector is advisory.

set -uo pipefail

# Recursion guard — prevents inspector from re-triggering itself if a check
# command happens to write to a watched file via its own tooling.
[[ "${INSPECTOR_NESTED:-0}" == "1" ]] && exit 0
export INSPECTOR_NESTED=1

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "inspector-post-write"

source "$PLUGIN_ROOT/scripts/lib/inspector-config.sh"
source "$PLUGIN_ROOT/scripts/lib/inspector-project-key.sh"
source "$PLUGIN_ROOT/scripts/lib/inspector-events.sh"
source "$PLUGIN_ROOT/scripts/lib/inspector-run.sh"

HOOK_INPUT=$(cat)
hook_health_context "$HOOK_INPUT"

# One jq pass for every field we need off the payload, rather than four forks
# over the same stdin. Each fork costs ~2.6ms against a hook whose whole skip
# path is ~100ms, and this prologue runs on the check path too (ecosystem-449.14).
#
# NUL-separated rather than line-separated: a file path may contain spaces, and
# pathologically a newline, which a line-based read would truncate. The four
# command substitutions this replaces preserved such a path, so anything less
# would be a regression. jq emits the NUL via its own \u0000 escape — bash
# strings are NUL-terminated, so it cannot be passed in with --arg.
CWD="" _HOOK_SESSION_ID="" TOOL_NAME="" TOOL_TARGET=""
_INSPECTOR_JQ_FIELDS='(.cwd // "") + "\u0000" + (.session_id // "") + "\u0000" + (.tool_name // "") + "\u0000" + ((.tool_input.file_path? // .tool_input.path?) // "") + "\u0000"'
{
	IFS= read -r -d '' CWD
	IFS= read -r -d '' _HOOK_SESSION_ID
	IFS= read -r -d '' TOOL_NAME
	IFS= read -r -d '' TOOL_TARGET
} < <(printf '%s' "$HOOK_INPUT" | jq -j "$_INSPECTOR_JQ_FIELDS" 2>/dev/null)
export _HOOK_SESSION_ID

# Bail on missing input — never block the tool call.
[[ -z "$CWD" ]] && exit 0
case "$TOOL_NAME" in
	Write|Edit|MultiEdit) ;;
	*) exit 0 ;;
esac
export INSPECTOR_TOOL_NAME="$TOOL_NAME"

# Touched file came off the same jq pass above.
[[ -z "$TOOL_TARGET" ]] && exit 0

# Canonicalize through the same helper the repo root uses. The containment
# check below is a prefix match, so both sides have to be resolved the same
# way — see inspector_canonical_path and ecosystem-foi.
CANONICAL=$(inspector_canonical_path "$TOOL_TARGET")
export INSPECTOR_FILE="$CANONICAL"

REPO_ROOT=$(inspector_project_repo_root "$CWD")
export INSPECTOR_REPO_ROOT="$REPO_ROOT"

# Project-key derivation — always succeeds (falls back to cwd hash).
PROJECT_KEY=$(inspector_project_key "$CWD")
export INSPECTOR_PROJECT_KEY="$PROJECT_KEY"

# File must live under repo root.
if [[ "$CANONICAL" != "$REPO_ROOT"/* && "$CANONICAL" != "$REPO_ROOT" ]]; then
	export INSPECTOR_FILE_RELATIVE="$CANONICAL"
	inspector_config_load "$REPO_ROOT"
	inspector_emit_whole_file_skipped "not_in_repo"
	exit 0
fi
export INSPECTOR_FILE_RELATIVE="${CANONICAL#"$REPO_ROOT"/}"

inspector_config_load "$REPO_ROOT"

# Excluded path containment check.
EXCLUDES=$(inspector_config_exclude_paths)
if [[ -n "$EXCLUDES" && "$EXCLUDES" != "null" && "$EXCLUDES" != "[]" ]]; then
	if jq -e --arg rel "$INSPECTOR_FILE_RELATIVE" \
		'any(.[]; . as $p | $rel | startswith($p + "/") or . == $p or (("/" + $rel) | contains("/" + $p + "/")))' \
		<<<"$EXCLUDES" >/dev/null 2>&1; then
		inspector_emit_whole_file_skipped "excluded_path"
		exit 0
	fi
fi

# Look up checks for this file's extension. Use the *longest* matching suffix
# so `.test.ts` matches before `.ts`. For now this is a simple two-step:
# first the multi-dot suffix, then the simple extension.
FILE_BASE="${CANONICAL##*/}"
EXT_LONG=""
EXT_SHORT=""
if [[ "$FILE_BASE" == *.*.* ]]; then
	EXT_LONG=".${FILE_BASE#*.}"
fi
if [[ "$FILE_BASE" == *.* ]]; then
	EXT_SHORT=".${FILE_BASE##*.}"
fi

CHECKS="[]"
if [[ -n "$EXT_LONG" ]]; then
	CANDIDATE=$(inspector_config_checks_for_extension "$EXT_LONG")
	if [[ -n "$CANDIDATE" && "$CANDIDATE" != "[]" ]]; then
		CHECKS="$CANDIDATE"
	fi
fi
if [[ "$CHECKS" == "[]" && -n "$EXT_SHORT" ]]; then
	CANDIDATE=$(inspector_config_checks_for_extension "$EXT_SHORT")
	if [[ -n "$CANDIDATE" && "$CANDIDATE" != "[]" ]]; then
		CHECKS="$CANDIDATE"
	fi
fi

if [[ "$CHECKS" == "[]" ]]; then
	inspector_emit_whole_file_skipped "no_extension_match"
	exit 0
fi

# Execute. Always exit 0 regardless of check outcomes.
inspector_run "$CHECKS" || true

exit 0

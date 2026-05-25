#!/usr/bin/env bash
# cartographer-post-write.sh — PostToolUse hook for Write / Edit / MultiEdit.
#
# Triggers a targeted single-file re-audit when a CLAUDE.md file is modified.
# Uses exact basename matching — editor swap files are excluded by definition.
# Always exits 0 (never blocks the tool call).

set -uo pipefail

# Recursion guard — prevents a claude -p subprocess spawned by run-audit.sh
# from re-triggering this hook.
[[ "${CARTOGRAPHER_NESTED:-0}" == "1" ]] && exit 0
export CARTOGRAPHER_NESTED=1

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

source "$PLUGIN_ROOT/scripts/lib/cartographer-config.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-project-key.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-lock.sh"

HOOK_INPUT=$(cat)
CWD=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
_HOOK_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
export _HOOK_SESSION_ID

[[ -z "$CWD" ]] && exit 0

# Extract the written file path from tool input
TOOL_TARGET=$(printf '%s' "$HOOK_INPUT" \
	| jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[[ -z "$TOOL_TARGET" ]] && exit 0

# Canonicalize the path (resolve symlinks where possible)
if command -v realpath &>/dev/null; then
	CANONICAL=$(realpath "$TOOL_TARGET" 2>/dev/null) || CANONICAL="$TOOL_TARGET"
elif command -v readlink &>/dev/null; then
	CANONICAL=$(readlink -f "$TOOL_TARGET" 2>/dev/null) || CANONICAL="$TOOL_TARGET"
else
	CANONICAL="$TOOL_TARGET"
fi

# Exact basename match — swap files (.swp, ~, .#) are excluded by this check
TARGET_BASENAME=$(basename "$CANONICAL")
[[ "$TARGET_BASENAME" != "CLAUDE.md" ]] && exit 0

REPO_ROOT=$(cartographer_project_repo_root "$CWD")
cartographer_config_load "$REPO_ROOT"

cartographer_config_enabled || exit 0

PROJECT_KEY=$(cartographer_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && exit 0

ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}"
CARTOGRAPHER_DIR="$ONLOOKER_DIR/cartographer/$PROJECT_KEY"
mkdir -p "$CARTOGRAPHER_DIR"

LOCK_FILE="$CARTOGRAPHER_DIR/audit.lock"

# Non-blocking lock — if a full scheduled audit is running, skip
cartographer_lock_acquire "$LOCK_FILE" || exit 0

export CARTOGRAPHER_DIR
export CARTOGRAPHER_TRIGGER="post_tool_use"
export CARTOGRAPHER_TARGET_FILE="$CANONICAL"
export ONLOOKER_DIR

nohup bash -c "
  trap 'source \"$PLUGIN_ROOT/scripts/lib/cartographer-lock.sh\"; cartographer_lock_release \"$LOCK_FILE\"' EXIT
  source \"$PLUGIN_ROOT/scripts/lib/cartographer-config.sh\"
  cartographer_config_load \"$REPO_ROOT\"
  exec \"$PLUGIN_ROOT/scripts/run-audit.sh\"
" >>"$CARTOGRAPHER_DIR/audit.log" 2>&1 &
printf '%d' "$!" >"$LOCK_FILE"

if command -v flock &>/dev/null; then
	exec 9>&- 2>/dev/null || true
fi

exit 0

#!/usr/bin/env bash
# cartographer-session-start.sh — SessionStart hook.
#
# Fast path: reads one JSON field, acquires a lock, and launches the audit
# pipeline as a detached background process. Returns in under 2 seconds.
#
# Invariant: this script NEVER calls claude -p or traverses the filesystem.
# All heavy work runs in run-audit.sh as an orphaned child.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

source "$PLUGIN_ROOT/scripts/lib/cartographer-config.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-project-key.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-lock.sh"

# Parse hook input
HOOK_INPUT=$(cat)
CWD=$(printf '%s' "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
_HOOK_SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)
export _HOOK_SESSION_ID

[[ -z "$CWD" ]] && exit 0

REPO_ROOT=$(cartographer_project_repo_root "$CWD")
cartographer_config_load "$REPO_ROOT"

cartographer_config_enabled || exit 0

PROJECT_KEY=$(cartographer_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && exit 0

ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}"
CARTOGRAPHER_DIR="$ONLOOKER_DIR/cartographer/$PROJECT_KEY"
mkdir -p "$CARTOGRAPHER_DIR"

LOCK_FILE="$CARTOGRAPHER_DIR/audit.lock"
STATE_FILE="$CARTOGRAPHER_DIR/last_audit_at"

# Determine if an audit is due
INTERVAL_HOURS=$(cartographer_config_audit_interval_hours)
FIRST_RUN_TRIGGER="session_start_first_run"
INTERVAL_TRIGGER="session_start_interval"

if [[ ! -f "$STATE_FILE" ]]; then
	TRIGGER="$FIRST_RUN_TRIGGER"
elif [[ -f "$STATE_FILE" ]]; then
	LAST=$(cat "$STATE_FILE" 2>/dev/null || printf '0')
	NOW=$(date +%s)
	ELAPSED=$(( NOW - LAST ))
	THRESHOLD=$(( INTERVAL_HOURS * 3600 ))
	if [[ "$ELAPSED" -lt "$THRESHOLD" ]]; then
		exit 0
	fi
	TRIGGER="$INTERVAL_TRIGGER"
fi

# Acquire lock non-blocking — skip if another session's audit is running
cartographer_lock_acquire "$LOCK_FILE" || exit 0

# Launch the audit detached — hook must return immediately
export CARTOGRAPHER_DIR
export CARTOGRAPHER_TRIGGER="$TRIGGER"
export ONLOOKER_DIR

nohup bash -c "
  trap 'source \"$PLUGIN_ROOT/scripts/lib/cartographer-lock.sh\"; cartographer_lock_release \"$LOCK_FILE\"' EXIT
  source \"$PLUGIN_ROOT/scripts/lib/cartographer-config.sh\"
  cartographer_config_load \"$REPO_ROOT\"
  exec \"$PLUGIN_ROOT/scripts/run-audit.sh\"
" >>"$CARTOGRAPHER_DIR/audit.log" 2>&1 &
AUDIT_PID=$!

# Write PID for macOS fallback path (also used by --force in skill)
printf '%d' "$AUDIT_PID" >"$LOCK_FILE"

# Release our flock fd; the child holds state via PID file
if command -v flock &>/dev/null; then
	exec 9>&- 2>/dev/null || true
fi

exit 0

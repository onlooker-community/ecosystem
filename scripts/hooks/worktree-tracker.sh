#!/usr/bin/env bash
# Onlooker Worktree Tracker
# Invoked by WorktreeCreate and WorktreeRemove for isolated agent/git worktree sessions.
#
# WorktreeCreate replaces default git behavior: this hook creates the worktree, records
# telemetry, and prints the absolute worktree path on stdout (stderr for diagnostics).
# WorktreeRemove records telemetry and removes the git worktree when present.
#
# Records canonical tool.shell.exec events (interim until worktree.* schema types exist) to:
#   ~/.onlooker/session-history/<session_id>.jsonl
#   ~/.onlooker/logs/onlooker-events.jsonl
#
# Usage:
#   echo "$INPUT" | worktree-tracker.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/validate-path.sh"
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
source "$SCRIPT_DIR/../lib/session-tracker.sh"
source "$SCRIPT_DIR/../lib/tool-history.sh"
source "$SCRIPT_DIR/../lib/worktree-tracker.sh"

hook_register "worktree-tracker" "Worktree Tracker" "Creates/removes git worktrees and records lifecycle telemetry"

INPUT=$(cat)

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // ""')
hook_set_context "$INPUT" "$HOOK_EVENT"

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

turn_state_export "$SESSION_ID"

worktree_tracker_emit() {
	local enriched_input="${1:-}"
	local record
	record=$(worktree_tracker_build_record "$enriched_input")
	if [[ -n "$record" ]]; then
		worktree_tracker_append "$SESSION_ID" "$record" || hook_failure "Failed to append session history"
		onlooker_append_event "$record" || hook_failure "Failed to append global event log"
	fi
}

case "$HOOK_EVENT" in
WorktreeCreate)
	NAME=$(echo "$INPUT" | jq -r '.name // ""')
	if [[ -z "$NAME" ]]; then
		echo "WorktreeCreate requires a worktree name" >&2
		exit 1
	fi

	REPO_ROOT=$(worktree_tracker_repo_root "$CWD")
	if [[ -z "$REPO_ROOT" ]]; then
		echo "WorktreeCreate requires a git repository (cwd: ${CWD:-unknown})" >&2
		exit 1
	fi

	START_MS=$(session_tracker_now_ms)
	WORKTREE_PATH=$(worktree_tracker_git_create "$REPO_ROOT" "$NAME")
	if [[ -z "$WORKTREE_PATH" ]]; then
		echo "Failed to create git worktree for name: $NAME" >&2
		exit 1
	fi

	BRANCH="worktree-${NAME}"
	worktree_tracker_record_created "$SESSION_ID" "$NAME" "$WORKTREE_PATH" "$BRANCH" \
		|| hook_failure "Failed to record worktree start time"

	END_MS=$(session_tracker_now_ms)
	export ONLOOKER_WORKTREE_DURATION_MS="$((END_MS - START_MS))"

	ENRICHED=$(echo "$INPUT" | jq \
		--arg path "$WORKTREE_PATH" \
		--arg branch "$BRANCH" \
		--arg repo "$REPO_ROOT" \
		'. + {worktree_path: $path, branch_name: $branch, repo_root: $repo}')
	RECORD=$(worktree_tracker_build_record "$ENRICHED")
	if [[ -n "$RECORD" ]]; then
		worktree_tracker_append "$SESSION_ID" "$RECORD" \
			|| hook_failure "Failed to append session history"
		onlooker_append_event "$RECORD" \
			|| hook_failure "Failed to append global event log"
	fi

	# stdout must be only the absolute worktree path for Claude Code
	printf '%s' "$WORKTREE_PATH"
	exit 0
	;;
WorktreeRemove)
	WORKTREE_PATH=$(echo "$INPUT" | jq -r '.worktree_path // ""')
	if [[ -z "$WORKTREE_PATH" ]]; then
		hook_success
		exit 0
	fi

	REPO_ROOT=$(worktree_tracker_repo_root "$CWD")
	DURATION_MS=$(worktree_tracker_duration_ms "$SESSION_ID" "$WORKTREE_PATH")
	if [[ -n "$DURATION_MS" ]]; then
		export ONLOOKER_WORKTREE_DURATION_MS="$DURATION_MS"
	fi

	ENRICHED=$(echo "$INPUT" | jq --arg repo "${REPO_ROOT:-}"} '. + {repo_root: $repo}')
	worktree_tracker_emit "$ENRICHED"

	if [[ -n "$REPO_ROOT" ]]; then
		worktree_tracker_git_remove "$REPO_ROOT" "$WORKTREE_PATH"
	fi

	worktree_tracker_clear_by_path "$SESSION_ID" "$WORKTREE_PATH"

	hook_success
	exit 0
	;;
*)
	hook_success
	exit 0
	;;
esac

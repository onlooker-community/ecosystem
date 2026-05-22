#!/usr/bin/env bash
# Worktree lifecycle helpers — git worktree create/remove and telemetry state.
#
# Source after validate-path.sh, onlooker-schema.sh, session-tracker.sh, and tool-history.sh:
#   source "$CLAUDE_PLUGIN_ROOT/scripts/lib/worktree-tracker.sh"

# Resolve repository root from hook cwd (must be inside a git work tree).
# Usage: repo_root=$(worktree_tracker_repo_root "$CWD")
worktree_tracker_repo_root() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && return 1
	git -C "$cwd" rev-parse --show-toplevel 2>/dev/null
}

# Create a Claude-style git worktree; prints absolute path on stdout, diagnostics on stderr.
# Usage: path=$(worktree_tracker_git_create "$REPO_ROOT" "$NAME")
worktree_tracker_git_create() {
	local repo_root="${1:-}"
	local name="${2:-}"
	[[ -z "$repo_root" || -z "$name" ]] && return 1

	local worktree_dir="${repo_root}/.claude/worktrees/${name}"
	local branch="worktree-${name}"

	mkdir -p "${repo_root}/.claude/worktrees"

	if [[ -d "$worktree_dir" ]]; then
		(cd "$worktree_dir" && pwd -P)
		return 0
	fi

	local base_ref="HEAD"
	if git -C "$repo_root" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
		base_ref=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)
	fi

	if git -C "$repo_root" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
		git -C "$repo_root" worktree add "$worktree_dir" "$branch" >&2 || return 1
	else
		git -C "$repo_root" worktree add -b "$branch" "$worktree_dir" "$base_ref" >&2 || return 1
	fi

	(cd "$worktree_dir" && pwd -P)
}

# Remove a git worktree when it is registered for the repo (best-effort).
# Usage: worktree_tracker_git_remove "$REPO_ROOT" "$WORKTREE_PATH"
worktree_tracker_git_remove() {
	local repo_root="${1:-}"
	local worktree_path="${2:-}"
	[[ -z "$repo_root" || -z "$worktree_path" ]] && return 0

	local resolved_path="$worktree_path"
	if [[ -d "$worktree_path" ]]; then
		resolved_path=$(cd "$worktree_path" && pwd -P)
	fi

	if git -C "$repo_root" worktree list --porcelain 2>/dev/null | grep -Fq "worktree ${resolved_path}"; then
		git -C "$repo_root" worktree remove --force "$resolved_path" >&2 || true
	fi
}

# Record worktree creation in the per-session tracker for duration on remove.
# Usage: worktree_tracker_record_created "$SESSION_ID" "$NAME" "$PATH" "$BRANCH"
worktree_tracker_record_created() {
	local session_id="${1:-}"
	local name="${2:-}"
	local worktree_path="${3:-}"
	local branch="${4:-}"
	[[ -z "$session_id" || -z "$name" || -z "$worktree_path" ]] && return 0

	turn_state_ensure_session "$session_id" || return 1

	local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
	local now_ms
	now_ms=$(session_tracker_now_ms)

	local temp_file
	temp_file=$(mktemp)
	if jq --arg name "$name" --arg path "$worktree_path" --arg branch "$branch" --argjson ms "$now_ms" \
		'.worktrees[$name] = {path: $path, branch: $branch, start_time_ms: $ms}' \
		"$tracker_file" >"$temp_file" 2>/dev/null; then
		mv "$temp_file" "$tracker_file"
	else
		rm -f "$temp_file"
		return 1
	fi
}

# Compute duration for a worktree path; prints empty when unknown.
# Usage: duration_ms=$(worktree_tracker_duration_ms "$SESSION_ID" "$WORKTREE_PATH")
worktree_tracker_duration_ms() {
	local session_id="${1:-}"
	local worktree_path="${2:-}"
	[[ -z "$session_id" || -z "$worktree_path" ]] && return 0

	local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
	[[ ! -f "$tracker_file" ]] && return 0

	local start_ms
	start_ms=$(
		jq -r --arg path "$worktree_path" '
			[.worktrees // {} | to_entries[] | select(.value.path == $path) | .value.start_time_ms] | first // empty
		' "$tracker_file" 2>/dev/null
	)
	[[ -z "$start_ms" || "$start_ms" == "null" ]] && return 0

	local now_ms elapsed
	now_ms=$(session_tracker_now_ms)
	elapsed=$((now_ms - start_ms))
	if [[ "$elapsed" -ge 0 ]]; then
		printf '%s' "$elapsed"
	fi
}

# Remove worktree timing entry after removal telemetry is recorded.
# Usage: worktree_tracker_clear_by_path "$SESSION_ID" "$WORKTREE_PATH"
worktree_tracker_clear_by_path() {
	local session_id="${1:-}"
	local worktree_path="${2:-}"
	[[ -z "$session_id" || -z "$worktree_path" ]] && return 0

	local tracker_file="${ONLOOKER_SESSION_TRACKERS_DIR}/${session_id}"
	[[ ! -f "$tracker_file" ]] && return 0

	local temp_file
	temp_file=$(mktemp)
	if jq --arg path "$worktree_path" '
			.worktrees |= with_entries(select(.value.path != $path))
		' "$tracker_file" >"$temp_file" 2>/dev/null; then
		mv "$temp_file" "$tracker_file"
	else
		rm -f "$temp_file"
	fi
}

# Build a canonical event from hook stdin (empty when unmapped).
# Usage: record=$(worktree_tracker_build_record "$INPUT")
worktree_tracker_build_record() {
	local input_json="${1:-}"
	onlooker_event_from_hook "$input_json"
}

# Append a canonical worktree event to session history.
# Usage: worktree_tracker_append "$SESSION_ID" "$event_json"
worktree_tracker_append() {
	tool_history_append "$1" "$2"
}

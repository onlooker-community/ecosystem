#!/usr/bin/env bash
# Bash wrappers for canonical Onlooker events (@onlooker-community/schema).
# Requires validate-path.sh to be sourced first.

_ONLOOKER_EVENT_JS="${_ONLOOKER_EVENT_JS:-${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/onlooker-event.mjs}"

# Resolved from this file's OWN location, never from a caller-supplied
# PLUGIN_ROOT and never by climbing to a repo root — both of those resolve in
# one checkout and nowhere else, and both fail by leaving every accessor
# undefined while the script still exits 0 (CLAUDE.md step 8). This lib is
# substrate-only (it is in neither SHARED_LIBS nor ON_DEMAND_LIBS), so its
# sibling is always the canonical copy.
# shellcheck source=onlooker-project-key.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/onlooker-project-key.sh"

# Export the project dimension for one hook payload's emission.
#
# Kept in one place because three chokepoints need it and each needs the same
# two things: the cwd the hook reported, and a resolve that does not pay for
# git on every event. Fails soft to an unset dimension — the emitter omits both
# fields when either is empty, which is the documented value for "not
# attributable".
_onlooker_resolve_project_for_hook() {
	local hook_input="${1:-}"
	local cwd=""
	if [[ -n "$hook_input" ]]; then
		cwd=$(printf '%s' "$hook_input" | jq -r '.cwd // empty' 2>/dev/null) || cwd=""
	fi
	onlooker_project_resolve_cached "$cwd"
}

# Append a validated canonical event JSON line to the global events log.
# Usage: onlooker_append_event "$event_json"
onlooker_append_event() {
	local event_json="${1:-}"
	[[ -z "$event_json" ]] && return 0

	ensure_dir_exists "$(dirname "$ONLOOKER_EVENTS_LOG")" || return 1
	printf '%s\n' "$event_json" >>"$ONLOOKER_EVENTS_LOG" 2>/dev/null
}

# Build a canonical event from Claude Code hook stdin JSON (prints event or empty).
# Usage: event=$(onlooker_event_from_hook "$INPUT")
onlooker_event_from_hook() {
	local hook_input="${1:-}"
	[[ -z "$hook_input" ]] && return 0

	if [[ ! -f "$_ONLOOKER_EVENT_JS" ]]; then
		return 1
	fi

	# The project dimension for every event that reaches the log through a hook
	# record: tool.*, skill.invoked, task.*, and the worktree events all funnel
	# through here (tool-history.sh, skill-usage.sh, task-tracker.sh and
	# worktree-tracker.sh each build their record with this one function). That
	# is the 79% of events ONL-129 exists for, and resolving HERE rather than in
	# each of those hooks is what keeps a future hook from silently joining the
	# 79% — the invisible-divergence risk the design names.
	#
	# `.cwd` from the hook payload, not $(pwd): the hook process's own directory
	# is not guaranteed to be the session's, which is exactly why Claude Code
	# puts cwd on the wire. Resolution is cached, so this costs ~1ms after the
	# first hook of a session.
	_onlooker_resolve_project_for_hook "$hook_input"

	printf '%s' "$hook_input" | ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="$ONLOOKER_PLUGIN_NAME" \
		ONLOOKER_TURN_NUMBER="${ONLOOKER_TURN_NUMBER:-}" \
		ONLOOKER_TASK_DURATION_MS="${ONLOOKER_TASK_DURATION_MS:-}" \
		ONLOOKER_WORKTREE_DURATION_MS="${ONLOOKER_WORKTREE_DURATION_MS:-}" \
		node "$_ONLOOKER_EVENT_JS" emit-from-hook 2>/dev/null
}

# Emit canonical event: validate via schema and append to events log.
# Usage: onlooker_emit_from_hook "$INPUT"
onlooker_emit_from_hook() {
	local event
	event=$(onlooker_event_from_hook "${1:-}")
	[[ -z "$event" ]] && return 0
	onlooker_append_event "$event"
}

# Validate stdin JSON against the canonical envelope; exit 0/1.
# Usage: echo "$event" | onlooker_validate_event
onlooker_validate_event() {
	[[ -f "$_ONLOOKER_EVENT_JS" ]] || return 1
	node "$_ONLOOKER_EVENT_JS" validate
}

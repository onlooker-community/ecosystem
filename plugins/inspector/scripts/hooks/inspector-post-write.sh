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
source "$PLUGIN_ROOT/scripts/lib/inspector-baseline.sh"
# shellcheck source=../lib/portable-lock.sh
source "$PLUGIN_ROOT/scripts/lib/portable-lock.sh"

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
[[ -z "$CWD" ]] && hook_health_exit 0
# Bash is here because a file edited through the shell -- a heredoc, sed -i, a
# short python script -- changed the filesystem without producing a Write/Edit
# tool call, and inspector's whole pitch is a per-edit gate. Matching on tool
# names left a hole exactly the width of the shell (ONL-28).
case "$TOOL_NAME" in
	Write|Edit|MultiEdit|Bash) ;;
	*) hook_health_exit 0 ;;
esac
export INSPECTOR_TOOL_NAME="$TOOL_NAME"

# Repo root is needed by both paths, and it is cheap (one git rev-parse).
REPO_ROOT=$(inspector_project_repo_root "$CWD")
export INSPECTOR_REPO_ROOT="$REPO_ROOT"

# ---------------------------------------------------------------------------
# One file's worth of work. Extracted from the old straight-line body so the
# Bash path can run it once per changed file; every former `hook_health_exit 0`
# in here is a `return 0`, because finishing with one file is not finishing the
# hook any more.
#
# Reads $REPO_ROOT from the enclosing scope and sets the two per-file exports
# inspector_run and the emit helpers consume.
# ---------------------------------------------------------------------------
_inspector_check_file() {
	local canonical="${1:-}"
	[[ -z "$canonical" ]] && return 0

	export INSPECTOR_FILE="$canonical"

	# File must live under repo root.
	if [[ "$canonical" != "$REPO_ROOT"/* && "$canonical" != "$REPO_ROOT" ]]; then
		export INSPECTOR_FILE_RELATIVE="$canonical"
		inspector_emit_whole_file_skipped "not_in_repo"
		return 0
	fi
	export INSPECTOR_FILE_RELATIVE="${canonical#"$REPO_ROOT"/}"

	# Excluded path containment check.
	local excludes
	excludes=$(inspector_config_exclude_paths)
	if [[ -n "$excludes" && "$excludes" != "null" && "$excludes" != "[]" ]]; then
		if jq -e --arg rel "$INSPECTOR_FILE_RELATIVE" \
			'any(.[]; . as $p | $rel | startswith($p + "/") or . == $p or (("/" + $rel) | contains("/" + $p + "/")))' \
			<<<"$excludes" >/dev/null 2>&1; then
			inspector_emit_whole_file_skipped "excluded_path"
			return 0
		fi
	fi

	# Look up checks for this file's extension. Use the *longest* matching
	# suffix so `.test.ts` matches before `.ts`. For now this is a simple
	# two-step: first the multi-dot suffix, then the simple extension.
	local file_base ext_long="" ext_short="" checks="[]" candidate
	file_base="${canonical##*/}"
	if [[ "$file_base" == *.*.* ]]; then
		ext_long=".${file_base#*.}"
	fi
	if [[ "$file_base" == *.* ]]; then
		ext_short=".${file_base##*.}"
	fi

	if [[ -n "$ext_long" ]]; then
		candidate=$(inspector_config_checks_for_extension "$ext_long")
		if [[ -n "$candidate" && "$candidate" != "[]" ]]; then
			checks="$candidate"
		fi
	fi
	if [[ "$checks" == "[]" && -n "$ext_short" ]]; then
		candidate=$(inspector_config_checks_for_extension "$ext_short")
		if [[ -n "$candidate" && "$candidate" != "[]" ]]; then
			checks="$candidate"
		fi
	fi

	if [[ "$checks" == "[]" ]]; then
		inspector_emit_whole_file_skipped "no_extension_match"
		return 0
	fi

	# Execute. Outcomes never change the hook's status — inspector is advisory.
	inspector_run "$checks" || true
	return 0
}

# ---------------------------------------------------------------------------
# Decide which files this invocation is about.
# ---------------------------------------------------------------------------
TARGETS=()

if [[ "$TOOL_NAME" == "Bash" ]]; then
	# THE PRE-CHECK RUNS BEFORE PROJECT KEY AND CONFIG LOAD, ON PURPOSE.
	#
	# inspector's fixed setup is 121-130ms (ecosystem-449.14), and Bash outruns
	# Edit roughly 30:1, so hooking Bash without deciding first would add
	# seconds per session for shell calls that touched nothing. Asking git what
	# moved costs ~21ms measured on this repo, so a no-op shell call — the
	# common case by far — pays only that and leaves.
	#
	# The read → decide → advance cycle is held under one lock. Parallel Bash
	# calls inside a single turn are routine, and without it every concurrent
	# hook reads the same not-yet-advanced baseline, independently concludes the
	# same edit is new, and lints it once each (ecosystem-449.13 I3).
	[[ -z "$REPO_ROOT" ]] && hook_health_exit 0

	BASELINE_FILE=$(inspector_baseline_path "$(inspector_baseline_scope_id "$REPO_ROOT")")
	BASELINE_LOCK="${BASELINE_FILE}.lock"
	mkdir -p "$(dirname "$BASELINE_FILE")" 2>/dev/null || true

	# Failing to lock means another hook is mid-cycle and will handle whatever
	# moved. Exiting is correct, not a loss: the work is not dropped, it is
	# attributed to the holder.
	if ! lock_acquire "$BASELINE_LOCK" 5; then
		hook_health_exit 0
	fi

	CHANGED=$(inspector_changed_files "$REPO_ROOT" "$BASELINE_FILE")
	# Advance before releasing, so the next caller in line sees a baseline that
	# already accounts for these files and finds nothing left to do.
	inspector_baseline_write "$REPO_ROOT" "$BASELINE_FILE"
	lock_release "$BASELINE_LOCK"

	[[ -z "$CHANGED" ]] && hook_health_exit 0

	while IFS= read -r _rel; do
		[[ -z "$_rel" ]] && continue
		TARGETS+=("${REPO_ROOT}/${_rel}")
	done <<<"$CHANGED"
else
	# Touched file came off the same jq pass above.
	[[ -z "$TOOL_TARGET" ]] && hook_health_exit 0
	# Canonicalize through the same helper the repo root uses. The containment
	# check is a prefix match, so both sides have to be resolved the same way —
	# see inspector_canonical_path and ecosystem-foi.
	TARGETS+=("$(inspector_canonical_path "$TOOL_TARGET")")
fi

# `${TARGETS[@]+...}` because bash 3.2 errors on an empty array under set -u,
# and 3.2 is /bin/bash on macOS.
[[ "${#TARGETS[@]}" -eq 0 ]] && hook_health_exit 0

# ---------------------------------------------------------------------------
# Setup paid once, however many files came out of the step above.
# ---------------------------------------------------------------------------
PROJECT_KEY=$(inspector_project_key "$CWD")
export INSPECTOR_PROJECT_KEY="$PROJECT_KEY"
inspector_config_load "$CWD"

for _target in "${TARGETS[@]+"${TARGETS[@]}"}"; do
	_inspector_check_file "$_target"
done

hook_health_exit 0

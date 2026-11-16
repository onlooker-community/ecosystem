#!/usr/bin/env bash
# Which files in a worktree this session changed (ecosystem-449.42).
#
# A worktree can hold more than one session's uncommitted work at a time, so
# "the tree is dirty" says nothing about what THIS session did. The Stop gate
# used to judge the whole tree's diff against one session's transcript, and run
# a paid judge for an idle session whenever a neighbor had left the tree dirty.
#
# The transcript is the attribution: every Edit, Write, MultiEdit and
# NotebookEdit it records names an absolute path. Those paths, kept to the ones
# inside this worktree and still dirty, are this session's changes — the same
# way compass takes file paths from the tool input rather than from the tree.
#
# A file changed only through Bash (sed, mv, codegen) is not in the transcript
# as an edit and so is not attributed. That under-reports this session's work;
# it never attributes another session's, which is the failure this exists for.
#
# Every git call passes --literal-pathspecs: the paths come from a transcript,
# and one starting with `:` would otherwise be read as pathspec magic.

# Usage: tribunal_session_edited_files <transcript_path> <worktree_root>
# Prints each path this session edited inside the worktree, relative to it, one
# per line, deduplicated.
tribunal_session_edited_files() {
	local transcript="$1" root="$2"
	[[ -n "$transcript" && -f "$transcript" && -n "$root" ]] || return 0
	# grep first so jq parses only the lines that can hold a tool call; a long
	# session's transcript runs to megabytes. -R with fromjson? skips any line
	# that is not valid JSON instead of failing the whole read.
	grep -F '"tool_use"' "$transcript" 2>/dev/null \
		| jq -rR '
			fromjson? | select(.type == "assistant") | .message.content[]?
			| select(.type == "tool_use"
				and (.name | IN("Edit", "Write", "MultiEdit", "NotebookEdit")))
			| (.input.file_path // .input.notebook_path // empty) | strings
			| select(startswith("/"))
		' 2>/dev/null \
		| tribunal_paths_in_worktree "$root"
}

# Usage: tribunal_paths_in_worktree <worktree_root>
# Reads absolute paths on stdin; prints each one inside the worktree, relative
# to it, deduplicated. Both sides are compared in physical form: git reports
# the root with symlinks resolved, while a transcript keeps whatever spelling
# the session used, so on macOS /var/... would never prefix-match git's
# /private/var/.... Deduplicated before the loop, which resolves each path's
# directory once. Shared by the gate and the nudge.
tribunal_paths_in_worktree() {
	local root="$1" root_phys p raw dir last_raw="" last_phys="" last_ok=0
	[[ -n "$root" ]] || return 0
	root_phys=$(cd "$root" 2>/dev/null && pwd -P) || return 0
	sort -u \
		| while IFS= read -r p; do
			# A caller's nocasematch would make the prefix case below match a
			# sibling that differs only in case; this subshell keeps its own.
			shopt -u nocasematch
			# sort -u keeps a directory's files together, so one lookup serves the run of them.
			raw="${p%/*}/"
			if [[ "$raw" != "$last_raw" ]]; then
				last_raw="$raw"
				last_ok=0
				if dir=$(cd "$raw" 2>/dev/null && pwd -P); then
					last_ok=1
					last_phys="$dir"
				fi
			fi
			# A directory that no longer exists holds nothing to count.
			[[ $last_ok -eq 1 ]] || continue
			p="${last_phys%/}/${p##*/}"
			case "$p" in
				"$root_phys"/*) printf '%s\n' "${p#"$root_phys"/}" ;;
			esac
		done \
		| sort -u
}

# Usage: tribunal_dirty_files <worktree_root> [path...]
# Prints each file that differs from HEAD (staged or not) or is untracked, one
# per line. With paths, only those paths are considered; with none, the whole
# worktree is.
tribunal_dirty_files() {
	local root="$1"
	shift
	[[ -n "$root" ]] || return 0
	{
		if git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
			git --literal-pathspecs -C "$root" diff --name-only HEAD -- "$@" 2>/dev/null
		else
			git --literal-pathspecs -C "$root" ls-files -m -- "$@" 2>/dev/null
		fi
		git --literal-pathspecs -C "$root" ls-files -o --exclude-standard -- "$@" 2>/dev/null
	} | sort -u
}

# Usage: tribunal_diff_summary <worktree_root> <path>...
# A diff stat over the given paths, with each untracked one listed after it:
# `git diff --stat` leaves out files git does not track, and a session's Write
# of a new file is exactly that.
tribunal_diff_summary() {
	local root="$1"
	shift
	[[ -n "$root" && $# -gt 0 ]] || return 0
	if git -C "$root" rev-parse --verify -q HEAD >/dev/null 2>&1; then
		git --literal-pathspecs -C "$root" diff HEAD --stat -- "$@" 2>/dev/null
	else
		git --literal-pathspecs -C "$root" diff --stat -- "$@" 2>/dev/null
	fi
	git --literal-pathspecs -C "$root" ls-files -o --exclude-standard -- "$@" 2>/dev/null \
		| sed 's/$/ | new file, untracked/'
}

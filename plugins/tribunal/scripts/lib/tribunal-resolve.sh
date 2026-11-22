#!/usr/bin/env bash
# What happens to a /tribunal run's changes after the jury does not accept
# them (ONL-308).
#
# A rejected or exhausted run leaves the actor's edits on disk, and until this
# lib nothing recorded what the person did next, so tribunal had no override
# rate for a calibrator to read (ONL-158). The skill now asks: keep the
# changes, discard them, or retry. This lib holds the parts of that which can
# be tested: the baseline a run takes when it starts, the discard, and the
# payload of the tribunal.session.resolved event that records the answer.
#
# Discard must never touch work that was there before the run. The baseline
# records every file already dirty or untracked, with a hash of its contents,
# and discard leaves each of those alone. One the actor changed again is named
# to the person instead, so they can sort it out by hand.
#
# Every git call that takes a path passes --literal-pathspecs, as
# tribunal-session-files.sh does: a path starting with `:` would otherwise be
# read as pathspec magic.

# _tribunal_dirty_entries <root>
# Prints each dirty or untracked path as "XY path", NUL-terminated. With
# --no-renames a rename reads as a deletion plus an addition, so every entry
# holds exactly one path. -uall lists the files inside an untracked directory
# rather than the directory.
_tribunal_dirty_entries() {
	git -C "$1" --literal-pathspecs status --porcelain=v1 -z --no-renames --untracked-files=all
}

# _tribunal_content_hash <root> <path>
# Prints the blob hash of the file's current contents, or nothing when the
# file does not exist.
_tribunal_content_hash() {
	if [ -f "$1/$2" ] || [ -L "$1/$2" ]; then
		git -C "$1" hash-object --no-filters -- "$2" 2>/dev/null
	fi
}

# Usage: tribunal_baseline_write <task_dir> <worktree>
# Writes <task_dir>/baseline.json: the worktree root, HEAD, and every path that
# is dirty or untracked right now, with the hash of its contents ("" for a file
# deleted from the worktree). Returns 1 and writes nothing outside a git
# worktree or before the first commit. There is then nothing to restore to, and
# the skill does not offer Discard.
tribunal_baseline_write() {
	local task_dir="$1" worktree="$2" root head entry path tmp
	local -a args=()
	root=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || return 1
	head=$(git -C "$root" rev-parse --verify --quiet HEAD) || return 1
	while IFS= read -r -d '' entry; do
		path="${entry:3}"
		args+=("$path" "$(_tribunal_content_hash "$root" "$path")")
	done < <(_tribunal_dirty_entries "$root")
	mkdir -p "$task_dir" || return 1
	# Written to a temp file and moved into place only when jq succeeds, so a
	# failed run leaves no empty or partial baseline.json.
	tmp=$(mktemp "${task_dir}/baseline.XXXXXX") || return 1
	if jq -n --arg root "$root" --arg head "$head" '
		$ARGS.positional as $a
		| {root: $root, head: $head,
		   dirty: [range(0; $a | length; 2) | {path: $a[.], hash: $a[. + 1]}]}
	' --args ${args[@]+"${args[@]}"} > "$tmp"; then
		mv -f "$tmp" "${task_dir}/baseline.json" || {
			rm -f "$tmp"
			return 1
		}
	else
		rm -f "$tmp"
		return 1
	fi
}

# Usage: tribunal_discard <task_dir>
# Restores every file the actor changed that was clean when the run started. A
# tracked file goes back to HEAD in the index and the worktree. An untracked
# file is deleted. A file in the baseline is never touched; one whose contents
# changed since the baseline was taken is counted and named, including one the
# actor put back to HEAD or deleted, which no longer shows in git status.
#
# Prints "<restored> <left>" on the first line, then each left path, one per
# line. A path that could not be restored or deleted is named on stderr as
# "tribunal: could not restore <path>".
#
# Returns:
#   0  success
#   1  no baseline, or one that does not validate; nothing touched
#   2  HEAD moved since the baseline; nothing touched. The actor committed, and
#      restoring to the new HEAD would keep its commit while reporting a discard
#   3  one or more paths could not be restored or deleted
#
# The baseline is validated and loaded once, before any change. A baseline that
# cannot be read must fail closed: treating "could not read" as "not in the
# baseline" would delete the person's own files. Paths are read NUL-separated
# with jq -j, which works on jq 1.6 (--raw-output0 needs 1.7).
tribunal_discard() {
	local baseline="$1/baseline.json" root head entry status path i found hash
	local restored=0 left=0 failed=0 loaded
	local -a entries=() left_paths=() base_paths=() base_hashes=() base_seen=()
	[ -f "$baseline" ] || return 1
	jq -e '
		(.root | type == "string" and length > 0)
		and (.head | type == "string" and length > 0)
		and (.dirty | type == "array"
			and all(.[]; type == "object"
				and (.path | type == "string")
				and (.hash | type == "string")))
	' "$baseline" > /dev/null 2>&1 || return 1
	root=$(jq -r '.root' "$baseline") || return 1
	head=$(jq -r '.head' "$baseline") || return 1
	[ "$(git -C "$root" rev-parse --verify --quiet HEAD)" = "$head" ] || return 2

	# Loaded through a file so a jq failure is seen, which a process
	# substitution would hide.
	loaded=$(mktemp) || return 1
	if ! jq -j '.dirty[] | .path, "\u0000", .hash, "\u0000"' "$baseline" > "$loaded"; then
		rm -f "$loaded"
		return 1
	fi
	while IFS= read -r -d '' path && IFS= read -r -d '' hash; do
		base_paths+=("$path")
		base_hashes+=("$hash")
		base_seen+=(0)
	done < "$loaded"
	rm -f "$loaded"

	# Read in full before changing anything. git status can hold index.lock
	# while it refreshes the index, and a restore running against a status
	# still streaming would fail on that lock.
	while IFS= read -r -d '' entry; do
		entries+=("$entry")
	done < <(_tribunal_dirty_entries "$root")

	for entry in ${entries[@]+"${entries[@]}"}; do
		status="${entry:0:2}"
		path="${entry:3}"
		found=-1
		i=0
		while [ "$i" -lt "${#base_paths[@]}" ]; do
			if [ "${base_paths[$i]}" = "$path" ]; then
				found=$i
				break
			fi
			i=$((i + 1))
		done
		if [ "$found" -ge 0 ]; then
			base_seen[found]=1
			if [ "$(_tribunal_content_hash "$root" "$path")" != "${base_hashes[$found]}" ]; then
				left=$((left + 1))
				left_paths+=("$path")
			fi
		elif [ "$status" = "??" ]; then
			if rm -f -- "${root}/${path}" 2>/dev/null; then
				restored=$((restored + 1))
			else
				echo "tribunal: could not restore ${path}" >&2
				failed=$((failed + 1))
			fi
		elif git -C "$root" --literal-pathspecs restore --source=HEAD --staged --worktree -- "$path" 2>/dev/null; then
			restored=$((restored + 1))
		else
			echo "tribunal: could not restore ${path}" >&2
			failed=$((failed + 1))
		fi
	done

	# A baseline entry that is not in the status now was dirty then and is clean
	# or gone now: the actor reverted or deleted it. Nothing is left to restore,
	# but the person's work changed, so it is named.
	i=0
	while [ "$i" -lt "${#base_paths[@]}" ]; do
		if [ "${base_seen[$i]}" -eq 0 ]; then
			left=$((left + 1))
			left_paths+=("${base_paths[$i]}")
		fi
		i=$((i + 1))
	done

	printf '%s %s\n' "$restored" "$left"
	[ "$left" -eq 0 ] || printf '%s\n' "${left_paths[@]}"
	[ "$failed" -eq 0 ] || return 3
	return 0
}

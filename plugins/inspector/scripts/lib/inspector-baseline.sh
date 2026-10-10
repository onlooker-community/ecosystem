#!/usr/bin/env bash
# Change detection for shell-shaped edits (ONL-28 / ecosystem-6dv).
#
# inspector's PostToolUse matcher used to be Write/Edit/MultiEdit -- TOOL
# CALLS, not changes to the filesystem. A file edited through the shell (a
# heredoc, sed -i, a short python script) was never linted, so the per-edit
# gate had a hole exactly the width of the shell.
#
# The Bash branch cannot read a path out of tool_input, so git is the source of
# truth: compare the work tree against a rolling per-session baseline of content
# shas and check whatever moved. Same approach ecosystem-449.13 built for
# lineage, deliberately reimplemented rather than shared -- inspector needs only
# "which paths changed", none of lineage's record qualifiers, content scopes or
# ledger identity, so this is about a third of the size. If a third consumer
# appears, that is the point to extract one vendored lib.
#
# WHY CONTENT SHAS AND NOT MTIME OR PLAIN `git status`:
#   - plain dirty-file listing re-checks the same file on every subsequent Bash
#     call for as long as it stays dirty, which in a session like this one means
#     dozens of redundant runs.
#   - mtime moves when a tool rewrites a file byte-identically (a formatter that
#     changed nothing), so it reports work that is not there.
# A content sha changes exactly when the bytes do.
#
# COST, which is the whole reason this is shaped as a pre-check:
# inspector's fixed setup is 121-130ms (ecosystem-449.14, after its 4-5x claim
# was corrected), and Bash outruns Edit roughly 30:1. `git status --porcelain`
# measures ~9.5ms on this repo and does not vary with the number of dirty files.
# So the hook asks "did anything change" for ~10ms BEFORE paying for config
# load, project key, or anything else, and a no-op shell call -- the common
# case by far -- pays only that.

# A cheap identity for the baseline file. Deliberately NOT the project key:
# resolving that involves a remote-URL lookup, which is part of the cost this
# pre-check exists to avoid. The baseline is per-checkout scratch, is never
# joined to anything durable, and so does not need the project key's identity.
inspector_baseline_scope_id() {
	local root="${1:-}"
	[[ -z "$root" ]] && return 0
	# git hash-object on a tiny stdin is one fork and git is already required
	# here; this avoids depending on which of openssl/sha256sum/shasum exists.
	printf '%s' "$root" | git hash-object --stdin 2>/dev/null | cut -c1-12
}

inspector_baseline_path() {
	local scope="${1:-}"
	[[ -z "$scope" ]] && return 0
	printf '%s/inspector/baselines/%s' "${ONLOOKER_DIR:-$HOME/.onlooker}" "$scope"
}

# Paths worth considering: whatever git already thinks is dirty, including
# untracked. Scales with the size of the change, not the size of the repo.
#
# `git status --porcelain=v1 -z` rather than `git diff --name-only HEAD`: the
# latter reports only TRACKED files, so a shell command creating a new file
# would be invisible -- the same gap this exists to close.
inspector_candidate_paths() {
	local root="${1:-}" rec status path
	[[ -z "$root" ]] && return 0
	# No `rev-parse --is-inside-work-tree` guard: outside a repo `git status`
	# already produces nothing, which every caller treats as "no candidates".
	# The guard was a second fork on a path whose whole budget is ~10ms.
	while IFS= read -r -d '' rec; do
		[[ -z "$rec" ]] && continue
		status="${rec:0:2}"
		path="${rec:3}"
		[[ -z "$path" ]] && continue
		printf '%s\n' "$path"
		# A rename or copy emits a companion bare-old-path record; drop it.
		if [[ "$status" == *R* || "$status" == *C* ]]; then
			read -r -d '' rec || true
		fi
	done < <(git -C "$root" status --porcelain=v1 -z --untracked-files=all 2>/dev/null) || true
}

# A snapshot of the dirty set: "<blob-sha> <TAB> <rel-path>" per line, sorted.
#
# PLAIN TEXT AND TWO FORKS, both deliberate. The first cut of this used a JSON
# baseline, hashed each file separately and built the object with two `jq -Rs`
# calls per path. Measured on this repo with three dirty files it cost 67ms per
# no-op call -- against inspector's 121-130ms fixed setup (ecosystem-449.14),
# that saves only half, and at the ~30:1 ratio of Bash calls to Edit calls it
# would add seconds of pure overhead per session for nothing. The forks were
# the whole cost, not the git call.
#
# So: one `git status` and ONE `git hash-object` for every file at once, and no
# jq at all. git is already a hard dependency on this path, which also sidesteps
# the openssl/sha256sum/shasum portability dance. The sha is a git blob hash --
# content-addressed, which is all change detection needs.
inspector_baseline_snapshot() {
	local root="${1:-}"
	[[ -z "$root" ]] && return 0
	local -a rels=()
	local rel
	while IFS= read -r rel; do
		[[ -z "$rel" ]] && continue
		# Directories appear in porcelain output for untracked trees; and a path
		# can vanish between the status call and this one.
		[[ -f "${root}/${rel}" ]] || continue
		rels+=("$rel")
	done < <(inspector_candidate_paths "$root")
	[[ "${#rels[@]}" -eq 0 ]] && return 0

	# hash-object preserves input order, so zip its output back onto the paths.
	local -a shas=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] && shas+=("$line")
	done < <(git -C "$root" hash-object -- "${rels[@]}" 2>/dev/null)
	[[ "${#shas[@]}" -ne "${#rels[@]}" ]] && return 0

	local i
	for (( i = 0; i < ${#rels[@]}; i++ )); do
		printf '%s	%s\n' "${shas[$i]}" "${rels[$i]}"
	done | sort
}

# Relative paths whose content differs from the recorded baseline.
#
# comm -23 reports lines present only in the current snapshot, which covers
# both "changed since baseline" and "did not exist at baseline". A missing
# baseline file means everything currently dirty is reported -- the first Bash
# call in a checkout has nothing to compare against, and checking the dirty set
# once is the safe reading.
inspector_changed_files() {
	local root="${1:-}" baseline_file="${2:-}"
	[[ -z "$root" ]] && return 0

	local cur
	cur=$(inspector_baseline_snapshot "$root")
	[[ -z "$cur" ]] && return 0

	if [[ -z "$baseline_file" || ! -f "$baseline_file" ]]; then
		printf '%s\n' "$cur" | cut -f2-
		return 0
	fi

	comm -23 <(printf '%s\n' "$cur") <(sort "$baseline_file" 2>/dev/null) 2>/dev/null \
		| cut -f2-
}

# Replace the baseline with the current snapshot. Written via a temp file in the
# same directory so a concurrent reader never sees a half-written baseline.
inspector_baseline_write() {
	local root="${1:-}" baseline_file="${2:-}"
	[[ -z "$root" || -z "$baseline_file" ]] && return 0
	mkdir -p "$(dirname "$baseline_file")" 2>/dev/null || return 0
	local tmp="${baseline_file}.$$.tmp"
	inspector_baseline_snapshot "$root" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
	mv -f "$tmp" "$baseline_file" 2>/dev/null || rm -f "$tmp"
}

#!/usr/bin/env bash
# Detect file changes git noticed and no tool announced.
#
# lineage's PostToolUse matcher sees Edit/Write/MultiEdit — a TOOL CALL, not a
# change to the filesystem. An agent editing through the shell moves the same
# bytes past an unwatched path (ecosystem-449.13). This library asks git what
# changed instead of parsing shell commands: covering sed -i, tee, heredocs and
# python -c is open-ended, and a wrong parse writes a FALSE ledger entry, which
# is worse than a missing one.
#
# Baselines are scratch state and live under $ONLOOKER_DIR/lineage-baselines/,
# NEVER under $ONLOOKER_DIR/lineage/ — that path is on the durable never-touch
# list in scripts/onlooker-store-prune.mjs, and a per-session file there would
# recreate ecosystem-449.2 inside the store that bead just bounded.
#
# Requires lineage-record.sh sourced beforehand (for lineage_sha256).

# ---------------------------------------------------------------------------
# Baseline location
# ---------------------------------------------------------------------------

lineage_baseline_dir() {
	local key="${1:-unknown}" safe
	safe=$(printf '%s' "$key" | tr -c 'a-zA-Z0-9-' '_')
	printf '%s/lineage-baselines/%s' "${ONLOOKER_DIR:-${HOME}/.onlooker}" "$safe"
}

lineage_baseline_path() {
	local key="$1" sid="${2:-unknown}" safe_sid
	safe_sid=$(printf '%s' "$sid" | tr -c 'a-zA-Z0-9-' '_')
	printf '%s/%s.json' "$(lineage_baseline_dir "$key")" "$safe_sid"
}

# Cheap identity for the per-session baseline.
#
# Deliberately NOT lineage_project_key: resolving that shells out for the remote
# URL and costs ~39ms, which is part of the setup the Bash pre-gate exists to
# skip. The baseline is scratch and is never joined to the ledger, so it does
# not need the ledger's identity — only stability within a session.
lineage_baseline_scope_id() {
	local root="${1:-unknown}"
	lineage_sha256 "$root" | cut -c1-12
}

# ---------------------------------------------------------------------------
# Git state
# ---------------------------------------------------------------------------

lineage_file_sha() {
	local path="$1"
	[[ -f "$path" ]] || return 0
	lineage_sha256 "$(cat "$path" 2>/dev/null)"
}

# Repo-relative paths that differ from HEAD OR are untracked.
#
# `git status --porcelain=v1 -z` rather than `git diff --name-only HEAD`: the
# latter reports only TRACKED files, so a shell command creating a new file
# would be invisible — the same silent gap this bead exists to close. Porcelain
# reports modified, staged, and untracked in one call.
#
# --untracked-files=all overrides the user's status.showUntrackedFiles config
# (default "normal"), which collapses a wholly-untracked directory into ONE
# entry (`?? docs/`) instead of listing the files inside it. Left at that
# default, a shell command creating a file inside a brand-new directory would
# collapse to a directory path that fails lineage_file_sha's `[[ -f ]]` guard
# and never get recorded — the exact silent gap the -z switch above exists to
# close, reopened by a config knob this library must not depend on.
#
# -z gives NUL-terminated records, so paths with spaces survive. Each record is
# normally a 2-char status, a space, then the path -- EXCEPT for a rename or
# copy (status starts with R or C): git emits that as the status-prefixed NEW
# path followed by a SECOND, bare record holding only the OLD path, with no
# status prefix at all. Slicing that bare record the same way (dropping its
# first 3 characters) chops into the path itself and yields garbage, so it is
# consumed and discarded instead of emitted -- the old path no longer exists
# on disk, so there is nothing to hash for it anyway.
lineage_candidate_paths() {
	local root="$1" rec status path
	[[ -z "$root" ]] && return 0
	git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
	while IFS= read -r -d '' rec; do
		[[ -z "$rec" ]] && continue
		status="${rec:0:2}"
		path="${rec:3}"
		[[ -z "$path" ]] && continue
		printf '%s\n' "$path"
		if [[ "$status" == *R* || "$status" == *C* ]]; then
			# Discard the companion bare-old-path record a rename/copy emits.
			read -r -d '' rec || true
		fi
	done < <(git -C "$root" status --porcelain=v1 -z --untracked-files=all 2>/dev/null) || true
}

# Baseline JSON: { files: { <rel_path>: <sha>, ... } }
lineage_baseline_build() {
	local root="$1" files_json rel abs
	files_json='{}'
	while IFS= read -r rel; do
		[[ -z "$rel" ]] && continue
		abs="${root}/${rel}"
		files_json=$(printf '%s' "$files_json" \
			| jq -c --arg k "$rel" --arg v "$(lineage_file_sha "$abs")" '.[$k]=$v' 2>/dev/null) \
			|| files_json='{}'
	done < <(lineage_candidate_paths "$root")

	jq -cn --argjson f "$files_json" '{files: $f}' 2>/dev/null
}

# Paths whose contents differ from the baseline.
#
# Compares per-path content shas rather than a hash of `git status` output. A
# status hash cannot see a second edit to an already-modified file: the status
# line is byte-identical both times, so the edit would vanish — the same class
# of silent miss this bead is about. A path absent from the baseline is new to
# the working tree and always reported.
lineage_changed_files() {
	local root="$1" base="$2" rel abs cur old
	[[ -z "$root" ]] && return 0
	while IFS= read -r rel; do
		[[ -z "$rel" ]] && continue
		abs="${root}/${rel}"
		cur=$(lineage_file_sha "$abs")
		[[ -z "$cur" ]] && continue   # deleted or unreadable: nothing to record
		old=$(printf '%s' "$base" | jq -r --arg k "$rel" '.files[$k] // ""' 2>/dev/null)
		[[ "$cur" != "$old" ]] && printf '%s\n' "$rel"
	done < <(lineage_candidate_paths "$root")
}

# ---------------------------------------------------------------------------
# Record qualifiers
# ---------------------------------------------------------------------------

# delta     — the file was clean at baseline, so `git diff HEAD` IS this change.
# cumulative— it was already dirty, so the diff also carries earlier uncommitted
#             work. Recorded rather than hidden: lineage's lookup tolerates
#             over-inclusion (it over-attributes to a later change, never
#             returns nothing), and tagging keeps the imprecision auditable.
lineage_content_scope() {
	local base="$1" rel="$2" old
	old=$(printf '%s' "$base" | jq -r --arg k "$rel" '.files[$k] // ""' 2>/dev/null)
	if [[ -n "$old" ]]; then printf 'cumulative'; else printf 'delta'; fi
}

# Added lines from the working tree against HEAD, '+' markers stripped.
#
# An untracked file has nothing in HEAD to diff against and `git diff` prints
# nothing for it, so its whole content is the added content. Without this the
# newly-created-file case would be detected and then silently skipped for
# having no content — a miss disguised as a decision.
lineage_added_content() {
	local root="$1" rel="$2"
	if git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
		git -C "$root" diff --unified=0 HEAD -- "$rel" 2>/dev/null \
			| sed -n 's/^+\([^+].*\)$/\1/p' \
			|| true
	else
		cat "${root}/${rel}" 2>/dev/null || true
	fi
}

# Removed lines from the working tree against HEAD, '-' markers stripped.
#
# Used ONLY to count lines_removed. The ledger stores added content, never
# removed, so this never reaches a snippet. An untracked file has no removed
# side, which is why this mirrors added_content's tracked-file check.
lineage_removed_content() {
	local root="$1" rel="$2"
	if git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
		git -C "$root" diff --unified=0 HEAD -- "$rel" 2>/dev/null \
			| sed -n 's/^-\([^-].*\)$/\1/p' \
			|| true
	fi
}

# authored | tool_generated, from the Bash command string.
#
# DEFAULTS TO authored ON PURPOSE. If the unknown case defaulted to
# tool_generated and /lineage filtered those out, a writer nobody classified
# would vanish silently — which is this bug one layer up. An unrecognized
# command shows up as noise instead: visible, and fixable.
lineage_classify_command() {
	local cmd="$1"
	case "$cmd" in
		*"git checkout"* | *"git switch"* | *"git merge"* | *"git rebase"* \
			| *"git pull"* | *"git stash"* | *"git reset"* | *"git revert"* \
			| *"git apply"* | *"git cherry-pick"*)
			printf 'tool_generated' ;;
		*"npm install"* | *"npm ci"* | *"npm update"* \
			| *"pnpm install"* | *"pnpm ci"* | *"yarn install"* | *"bun install"*)
			printf 'tool_generated' ;;
		*biome* | *prettier* | *"black "* | *rustfmt* | *gofmt* | *"npm run format"*)
			printf 'tool_generated' ;;
		*release-please*)
			printf 'tool_generated' ;;
		*)
			printf 'authored' ;;
	esac
}

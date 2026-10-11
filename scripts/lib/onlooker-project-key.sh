#!/usr/bin/env bash
# Project key derivation for the substrate.
#
# Mirrors the per-plugin schemes (see tribunal-project-key.sh) so substrate
# artifacts partition identically to every plugin's. A project key is a stable
# 12-char hex identifier that survives:
#   - local rename of the repo directory
#   - cloning the same repo to a different path on the same machine
#   - moving the repo between machines, as long as the git remote is preserved
#   - worktrees (a worktree shares its parent repo's key)
#
# Resolution order:
#   1. SHA256("remote:<git remote get-url origin>") — machine-portable
#   2. SHA256("root:<realpath of the common-dir parent>") — repos with no remote
#
# Returns the first 12 hex chars, or empty when neither path resolves.
#
# This answers IDENTITY, not location. It deliberately resolves a linked
# worktree to its parent checkout so the two share a key. Anything that needs to
# read or diff the tree the session is actually in wants `git rev-parse
# --show-toplevel` instead — a worktree's files sit beside the parent, not
# beneath it. Conflating the two is ecosystem-449.37, mirroring lineage's
# ecosystem-449.33.

_onlooker_sha256_first12() {
	local input="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

onlooker_project_remote_url() {
	local cwd="${1:-}"
	[[ -z "$cwd" || ! -d "$cwd" ]] && return 0
	git -C "$cwd" remote get-url origin 2>/dev/null || true
}

# Worktree-aware: uses common-dir so worktrees share a key with the main repo.
onlooker_project_repo_root() {
	local cwd="${1:-}"
	[[ -z "$cwd" || ! -d "$cwd" ]] && return 0

	if ! git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		return 0
	fi

	local common_dir toplevel
	common_dir=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null) || return 0

	if [[ -n "$common_dir" && "$common_dir" != /* ]]; then
		common_dir="$(cd "$cwd" && cd "$common_dir" 2>/dev/null && pwd -P)" || common_dir=""
	fi

	if [[ -n "$common_dir" && -d "$common_dir" ]]; then
		toplevel="$(cd "$common_dir/.." 2>/dev/null && pwd -P)" || toplevel=""
	fi

	if [[ -z "$toplevel" ]]; then
		toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
		[[ -n "$toplevel" ]] && toplevel="$(cd "$toplevel" 2>/dev/null && pwd -P)"
	fi

	printf '%s' "$toplevel"
}

# Resolve the toplevel of the working tree the session is actually in.
#
# Distinct from onlooker_project_repo_root, which deliberately resolves a linked
# worktree to its parent checkout so both share a project key. That is the right
# answer for identity and the wrong one for git: a worktree's files sit beside
# the parent, not beneath it, so anything that reads or diffs the tree wants
# this root instead (ecosystem-449.37, mirroring lineage's ecosystem-449.33).
onlooker_worktree_root() {
	local cwd="${1:-}"
	[[ -z "$cwd" || ! -d "$cwd" ]] && return 0

	local toplevel
	toplevel=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 0
	[[ -z "$toplevel" ]] && return 0

	(cd "$toplevel" 2>/dev/null && pwd -P) || printf '%s' "$toplevel"
}

# Resolve key and basis in ONE git pass, exporting both.
#
# The emitter reads these two variables rather than taking arguments or
# deriving the key in JavaScript. A JS reimplementation that drifted from this
# one would silently stop matching the on-disk directory names under
# $ONLOOKER_DIR/<plugin>/<key>/, and that match is the entire point of the
# envelope field.
#
# Both variables are cleared first, so a second call for a non-repo directory
# does not leave the previous repo's key standing.
onlooker_project_resolve() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && cwd="$(pwd)"

	ONLOOKER_PROJECT_KEY=""
	ONLOOKER_PROJECT_BASIS=""
	export ONLOOKER_PROJECT_KEY ONLOOKER_PROJECT_BASIS

	local remote
	remote=$(onlooker_project_remote_url "$cwd")
	if [[ -n "$remote" ]]; then
		ONLOOKER_PROJECT_KEY=$(_onlooker_sha256_first12 "remote:$remote")
		ONLOOKER_PROJECT_BASIS="remote"
		return 0
	fi

	local root
	root=$(onlooker_project_repo_root "$cwd")
	if [[ -n "$root" ]]; then
		ONLOOKER_PROJECT_KEY=$(_onlooker_sha256_first12 "root:$root")
		ONLOOKER_PROJECT_BASIS="root"
		return 0
	fi

	return 0
}

# Compute the project key for the given cwd. Prints the key, or empty string.
#
# A thin wrapper over onlooker_project_resolve, which means every caller also
# populates ONLOOKER_PROJECT_KEY and ONLOOKER_PROJECT_BASIS. That is deliberate:
# it is what lets the emitter pick the dimension up without touching any of the
# call sites. Callers passing a directory other than the session's cwd should
# know they are setting the session-visible value too.
onlooker_project_key() {
	onlooker_project_resolve "${1:-}"
	printf '%s' "$ONLOOKER_PROJECT_KEY"
}

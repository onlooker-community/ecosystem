#!/usr/bin/env bash
# Project key derivation for Curator.
#
# Curator stores findings under the ecosystem-wide 12-char hex project key so
# state survives clone path changes and is shared across worktrees / clones of
# the same repo. (The typed memory store Curator audits lives at a different
# path keyed by the Claude Code per-checkout encoding; that path is resolved
# separately by curator-memory-reader.sh.)
#
# Resolution order:
#   1. SHA256(`git remote get-url origin`) — preferred, machine-portable
#   2. SHA256(realpath of `git rev-parse --show-toplevel`) — fallback for
#      repos without an origin remote
#
# Returns the first 12 hex chars. Empty when not in a git repo at all.

_curator_sha256_first12() {
	local input="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

curator_project_remote_url() {
	local cwd="${1:-}"
	[[ -z "$cwd" || ! -d "$cwd" ]] && return 0
	git -C "$cwd" remote get-url origin 2>/dev/null || true
}

curator_project_repo_root() {
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

# Compute the project key for the given cwd. Prints the key or empty.
# Usage: key=$(curator_project_key "$CWD")
curator_project_key() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && cwd="$(pwd)"

	local remote
	remote=$(curator_project_remote_url "$cwd")
	if [[ -n "$remote" ]]; then
		_curator_sha256_first12 "remote:$remote"
		return 0
	fi

	local root
	root=$(curator_project_repo_root "$cwd")
	if [[ -n "$root" ]]; then
		_curator_sha256_first12 "root:$root"
		return 0
	fi

	return 0
}

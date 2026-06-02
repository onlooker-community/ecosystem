#!/usr/bin/env bash
# Project key derivation for Counsel.
#
# Mirrors the tribunal/scribe project-key scheme so plugins partition storage
# identically. A project key is a stable 12-char hex identifier derived from
# the git remote URL (preferred) or repo root path (fallback).

_counsel_sha256_first12() {
	local input="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

counsel_project_remote_url() {
	local cwd="${1:-}"
	[[ -z "$cwd" || ! -d "$cwd" ]] && return 0
	git -C "$cwd" remote get-url origin 2>/dev/null || true
}

# Worktree-aware: uses common-dir so worktrees share a key with the main repo.
counsel_project_repo_root() {
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

counsel_project_key() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && cwd="$(pwd)"

	local remote
	remote=$(counsel_project_remote_url "$cwd")
	if [[ -n "$remote" ]]; then
		_counsel_sha256_first12 "remote:$remote"
		return 0
	fi

	local root
	root=$(counsel_project_repo_root "$cwd")
	if [[ -n "$root" ]]; then
		_counsel_sha256_first12 "root:$root"
		return 0
	fi

	return 0
}

counsel_project_dir() {
	local project_key="${1:-}"
	[[ -z "$project_key" ]] && return 1
	local onlooker_dir="${ONLOOKER_DIR:-${HOME}/.onlooker}"
	printf '%s' "${onlooker_dir}/counsel/${project_key}/briefs"
}

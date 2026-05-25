#!/usr/bin/env bash
# Project key derivation for Echo.
# Mirrors archivist/tribunal: stable 12-char hex key derived from the git remote
# or repo root, surviving renames, clones, and worktrees.

_echo_sha256_first12() {
	local input="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 2>/dev/null | cut -c1-12
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum 2>/dev/null | cut -c1-12
	else
		return 1
	fi
}

echo_project_remote_url() {
	local cwd="${1:-}"
	[[ -z "$cwd" || ! -d "$cwd" ]] && return 0
	git -C "$cwd" remote get-url origin 2>/dev/null || true
}

echo_project_repo_root() {
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

echo_project_key() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && cwd="$(pwd)"

	local remote
	remote=$(echo_project_remote_url "$cwd")
	if [[ -n "$remote" ]]; then
		_echo_sha256_first12 "remote:$remote"
		return 0
	fi

	local root
	root=$(echo_project_repo_root "$cwd")
	if [[ -n "$root" ]]; then
		_echo_sha256_first12 "root:$root"
		return 0
	fi

	return 0
}

# Stable test_id for a file path: first 16 chars of sha256 of the path.
echo_test_id_for_path() {
	local path="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$path" | shasum -a 256 2>/dev/null | cut -c1-16
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$path" | sha256sum 2>/dev/null | cut -c1-16
	else
		printf '%s' "$path" | od -A n -t x1 | tr -d ' \n' | cut -c1-16
	fi
}

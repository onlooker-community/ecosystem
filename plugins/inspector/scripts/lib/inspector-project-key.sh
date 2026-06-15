#!/usr/bin/env bash
# inspector-project-key.sh — stable 12-char hex project key.
#
# Derives a key that survives repo renames, clones, and worktrees.
# Algorithm:
#   1. git remote get-url origin → sha256("remote:" + url)[0:12]
#   2. Fallback: git rev-parse --show-toplevel → sha256("root:" + path)[0:12]
#   3. Non-git: sha256("cwd:" + pwd)[0:12]
#
# Usage:
#   key=$(inspector_project_key <cwd>)
#   root=$(inspector_project_repo_root <cwd>)

_inspector_sha256_first12() {
	local input="$1"
	if command -v sha256sum &>/dev/null; then
		printf '%s' "$input" | sha256sum | cut -c1-12
	elif command -v shasum &>/dev/null; then
		printf '%s' "$input" | shasum -a 256 | cut -c1-12
	else
		printf '%s' "$input" | python3 -c \
			'import sys,hashlib; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])'
	fi
}

inspector_project_repo_root() {
	local cwd="${1:-$(pwd)}"
	local root
	root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) && printf '%s' "$root" && return 0
	printf '%s' "$cwd"
}

inspector_project_remote_url() {
	local cwd="${1:-$(pwd)}"
	git -C "$cwd" remote get-url origin 2>/dev/null || true
}

inspector_project_key() {
	local cwd="${1:-$(pwd)}"
	local remote
	remote=$(inspector_project_remote_url "$cwd")
	if [[ -n "$remote" ]]; then
		_inspector_sha256_first12 "remote:${remote}"
		return 0
	fi

	local root
	root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
	if [[ -n "$root" ]]; then
		_inspector_sha256_first12 "root:${root}"
		return 0
	fi

	_inspector_sha256_first12 "cwd:${cwd}"
}

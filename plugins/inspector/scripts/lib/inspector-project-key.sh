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

# Resolve a path to its physical form — symlinks expanded, no trailing slash.
#
# The hook decides whether a touched file lives inside the repo by prefix-
# matching one canonicalized path against the other. Both sides MUST come
# through this one function. They used to be canonicalized independently
# (realpath for the file, `git rev-parse --show-toplevel` for the root), each
# with its own fallback, and on macOS /var is a symlink to /private/var — so
# whenever either mechanism fell back, the two sides landed in different
# namespaces and the prefix match failed. The hook then reported not_in_repo
# for a file plainly inside the repo, exiting 0 with no output. See
# ecosystem-foi, where that surfaced as an intermittent test failure.
#
# The last resort is `cd` + `pwd -P`, a bash builtin that needs no external
# tool, so this still returns a physical path when neither realpath nor a
# GNU-style `readlink -f` is available.
#
# Usage: canonical=$(inspector_canonical_path "$some_path")
inspector_canonical_path() {
	local p="${1:-}"
	[[ -z "$p" ]] && return 0

	local out
	if out=$(realpath "$p" 2>/dev/null) && [[ -n "$out" ]]; then
		printf '%s' "$out"
		return 0
	fi
	# BSD readlink has no -f, so this silently no-ops there and falls through.
	if out=$(readlink -f "$p" 2>/dev/null) && [[ -n "$out" ]]; then
		printf '%s' "$out"
		return 0
	fi

	if [[ -d "$p" ]]; then
		out=$(cd "$p" 2>/dev/null && pwd -P) && [[ -n "$out" ]] && {
			printf '%s' "$out"
			return 0
		}
	else
		local dir base
		dir=$(dirname "$p")
		base=$(basename "$p")
		out=$(cd "$dir" 2>/dev/null && pwd -P) && [[ -n "$out" ]] && {
			printf '%s/%s' "$out" "$base"
			return 0
		}
	fi

	# Nothing resolved it — hand back the input rather than an empty string,
	# so a caller comparing two of these still compares like with like.
	printf '%s' "$p"
}

inspector_project_repo_root() {
	local cwd="${1:-$(pwd)}"
	local root
	# Canonicalize BOTH the git answer and the fallback. git already returns a
	# physical path, so the first call is a no-op; the fallback is the caller's
	# raw cwd, which is exactly the case that used to diverge.
	root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) \
		&& [[ -n "$root" ]] \
		&& { inspector_canonical_path "$root"; return 0; }
	inspector_canonical_path "$cwd"
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

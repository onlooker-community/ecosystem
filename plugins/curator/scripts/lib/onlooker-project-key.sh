#!/usr/bin/env bash
# Project key derivation for the substrate.
#
# Mirrors the per-plugin schemes once carried separately by each plugin, so
# substrate artifacts partition identically to every plugin's. A project key
# is a stable 12-char hex identifier that survives:
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
#
# The export is visible only to a caller that invokes this function directly
# in the current shell. A caller that wraps the call in command substitution —
# `x=$(onlooker_project_resolve ...)` — runs it in a subshell, and the exports
# die with that subshell; nothing escapes to the parent. A caller that needs
# the basis, not just the key, must call this function directly (not through
# onlooker_project_key) and not through command substitution.
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
# A thin wrapper over onlooker_project_resolve. Every production call site uses
# `PROJECT_KEY=$(onlooker_project_key "$CWD")`, and command substitution runs
# the call in a subshell — so the ONLOOKER_PROJECT_KEY/ONLOOKER_PROJECT_BASIS
# exports onlooker_project_resolve sets are made and then discarded with that
# subshell on every one of them. This wrapper does NOT populate those variables
# for the caller's shell; it only prints the key. A caller that needs the basis
# must call onlooker_project_resolve directly, without command substitution.
onlooker_project_key() {
	onlooker_project_resolve "${1:-}"
	printf '%s' "$ONLOOKER_PROJECT_KEY"
}

# Resolve key and basis for EMISSION, memoized across a session's hooks.
#
# Same contract as onlooker_project_resolve — exports ONLOOKER_PROJECT_KEY and
# ONLOOKER_PROJECT_BASIS, both empty for a non-repo — but it answers from a
# cache when it can. This exists because the substrate's emit chokepoints are on
# the hot path: tool-history-tracker fires on EVERY tool call and costs ~81ms,
# and an uncached resolve adds ~22ms (a `git remote get-url` plus a shasum) for
# a value that is the same on every call of a session. The cache takes that to
# ~1ms, so the project dimension reaches the 79% of events that carried nothing
# without making the hottest hook in the system 27% slower.
#
# Two tiers:
#   1. an in-shell memo, for a hook that emits several events in one run
#   2. a TSV under $ONLOOKER_DIR, which is what carries the memo ACROSS the
#      separate processes a session's hooks actually are
#
# Negatives are cached too. A non-repo cwd costs two FAILING git calls to
# discover, every time, and $HOME is a cwd hooks genuinely see.
#
# Staleness is accepted deliberately: a repo that gains an origin remote keeps
# its root-derived key until the cache line is dropped. Both values stay
# internally consistent (the basis travels with the key, which is the invariant
# the envelope cares about), the key still matches the on-disk artifact
# directories written while it was cached, and a stale line is one `rm` from
# gone. Set ONLOOKER_PROJECT_CACHE=0 to bypass both tiers.
onlooker_project_resolve_cached() {
	local cwd="${1:-}"
	[[ -z "$cwd" ]] && cwd="$(pwd)"

	if [[ "${ONLOOKER_PROJECT_CACHE:-1}" == "0" ]]; then
		onlooker_project_resolve "$cwd"
		return 0
	fi

	# Tier 1: this shell already resolved this cwd.
	if [[ "${_ONLOOKER_PROJECT_MEMO_CWD:-__unset__}" == "$cwd" ]]; then
		ONLOOKER_PROJECT_KEY="${_ONLOOKER_PROJECT_MEMO_KEY:-}"
		ONLOOKER_PROJECT_BASIS="${_ONLOOKER_PROJECT_MEMO_BASIS:-}"
		export ONLOOKER_PROJECT_KEY ONLOOKER_PROJECT_BASIS
		return 0
	fi

	local cache_file="${ONLOOKER_DIR:-$HOME/.onlooker}/project-key-cache.tsv"

	# Tier 2: a previous process in this session resolved it. Read with the
	# shell's own `read` rather than grep/awk — the whole point is to not spend
	# a process here, and the file holds one line per project per machine.
	local lines=0
	if [[ -r "$cache_file" ]]; then
		local c_cwd c_key c_basis
		while IFS=$'\t' read -r c_cwd c_key c_basis || [[ -n "$c_cwd" ]]; do
			lines=$((lines + 1))
			if [[ "$c_cwd" == "$cwd" ]]; then
				ONLOOKER_PROJECT_KEY="$c_key"
				ONLOOKER_PROJECT_BASIS="$c_basis"
				export ONLOOKER_PROJECT_KEY ONLOOKER_PROJECT_BASIS
				_ONLOOKER_PROJECT_MEMO_CWD="$cwd"
				_ONLOOKER_PROJECT_MEMO_KEY="$c_key"
				_ONLOOKER_PROJECT_MEMO_BASIS="$c_basis"
				return 0
			fi
		done <"$cache_file"
	fi

	onlooker_project_resolve "$cwd"

	_ONLOOKER_PROJECT_MEMO_CWD="$cwd"
	_ONLOOKER_PROJECT_MEMO_KEY="$ONLOOKER_PROJECT_KEY"
	_ONLOOKER_PROJECT_MEMO_BASIS="$ONLOOKER_PROJECT_BASIS"

	# A cwd holding a tab would write a line that reads back as the wrong
	# fields, so skip the cache rather than poison it. Everything else appends:
	# one short printf in append mode is atomic under PIPE_BUF, so concurrent
	# hooks cannot tear a line, and a duplicate line is harmless because the
	# first match wins and both agree.
	#
	# Two details below are load-bearing, not style. Callers run under
	# `set -euo pipefail` (onlooker-emit.sh does), so a failing write must be
	# swallowed with `|| true`: otherwise an unwritable cache aborts the caller
	# before it emits, turning a cache miss into a DROPPED event. Caching is an
	# optimization and must never be able to fail the emission it exists to
	# speed up. And the redirection has to sit inside the `{ } 2>/dev/null`,
	# because a failing `>` or `>>` is reported by the SHELL rather than by
	# printf — a `2>/dev/null` on printf alone leaves "Permission denied"
	# printing into the session on every single event.
	if [[ "$cwd" != *$'\t'* ]]; then
		# Bound the file, because the scan above is linear and the inputs are
		# not: every throwaway directory a hook ever runs in earns a (negative)
		# line, and those never get reused. Measured, a 500-line cache costs
		# ~7ms to scan — closing on the ~22ms git call it exists to avoid, and
		# still growing. 256 is far above the real working set (~30 repos on
		# this machine), so this is a runaway guard, not an eviction policy:
		# starting over costs one resolve per live project and self-heals,
		# where evicting oldest-first would mean rewriting the file and racing
		# every concurrent hook for it.
		local line
		line=$(printf '%s\t%s\t%s' \
			"$cwd" "$ONLOOKER_PROJECT_KEY" "$ONLOOKER_PROJECT_BASIS")

		if mkdir -p "$(dirname "$cache_file")" 2>/dev/null; then
			if [[ "$lines" -ge 256 ]]; then
				{ printf '%s\n' "$line" >"$cache_file"; } 2>/dev/null || true
			else
				{ printf '%s\n' "$line" >>"$cache_file"; } 2>/dev/null || true
			fi
		fi
	fi
	return 0
}

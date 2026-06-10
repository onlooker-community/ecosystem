#!/usr/bin/env bash
# portable-lock.sh — vendored copy of the ecosystem substrate's portable lock.
#
# Vendored into the governor plugin so the ledger's atomic appends keep
# working when governor is installed standalone from the marketplace: the
# cache layout (~/.claude/plugins/cache/<owner>/governor/<version>/) does not
# include the ecosystem repo's top-level scripts/lib/. Without a local copy,
# lock_acquire would be undefined and governor_ledger_append would poison the
# ledger after exhausting its retries. This mirrors the per-plugin vendoring
# of governor-ulid.sh and friends.
# Keep in sync with scripts/lib/portable-lock.sh at the repo root.
#
# Portable advisory file locking via mkdir() atomicity.
#
# Replaces flock(1), which ships with util-linux on Linux but is not present
# in stock macOS. This matters because the Onlooker hooks run on user
# machines, not just in CI: a macOS user without util-linux would otherwise
# see concurrent writes to $ONLOOKER_DIR silently clobber each other.
#
# mkdir() is atomic on POSIX local filesystems, which is the only place
# $ONLOOKER_DIR ever lives. Network filesystems (NFS) do not guarantee
# atomicity, but Claude Code state is local-only.
#
# Usage:
#   lock_acquire "/path/to/file.lock" [timeout_seconds=5]
#   # ... critical section ...
#   lock_release "/path/to/file.lock"
#
# Avoid associative arrays so bash 3.2 (macOS default) keeps working.

# Acquire an exclusive lock at LOCKPATH. Returns 0 on success, 1 on timeout.
lock_acquire() {
	local lockpath="${1:-}"
	local timeout="${2:-5}"
	[[ -z "$lockpath" ]] && return 1

	local lockdir="${lockpath}.d"
	local waited=0
	# Poll at 10 Hz so a 5s timeout = 50 attempts.
	local max_iter=$((timeout * 10))
	while ! mkdir "$lockdir" 2>/dev/null; do
		if ((waited >= max_iter)); then
			return 1
		fi
		# `sleep 0.1` works on Linux + macOS; the `|| sleep 1` is a paranoid
		# fallback for embedded shells that only accept integer seconds.
		sleep 0.1 2>/dev/null || sleep 1
		waited=$((waited + 1))
	done
	return 0
}

# Release the lock previously acquired for LOCKPATH. Safe to call when the
# lock is not held (no-op in that case).
lock_release() {
	local lockpath="${1:-}"
	[[ -z "$lockpath" ]] && return 0
	rmdir "${lockpath}.d" 2>/dev/null || true
}

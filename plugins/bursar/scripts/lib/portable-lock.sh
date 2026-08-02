#!/usr/bin/env bash
# portable-lock.sh — vendored copy of the ecosystem substrate's portable lock.
#
# Vendored into the bursar plugin so the per-project ledger's atomic upserts
# keep working when bursar is installed standalone from the marketplace: the
# cache layout (~/.claude/plugins/cache/<owner>/bursar/<version>/) does not
# include the ecosystem repo's top-level scripts/lib/. Without a local copy,
# lock_acquire would be undefined and the SessionEnd upsert could clobber a
# concurrent writer. This mirrors the per-plugin vendoring of bursar-ulid.sh
# and friends.
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
# Uses exponential backoff under high contention to reduce cache-line thrashing.
lock_acquire() {
	local lockpath="${1:-}"
	local timeout="${2:-5}"
	[[ -z "$lockpath" ]] && return 1

	local lockdir="${lockpath}.d"
	local start_time
	start_time=$(date +%s 2>/dev/null) || start_time=0

	local backoff=10  # Start at 10ms (1/100s)
	while ! mkdir "$lockdir" 2>/dev/null; do
		# Check timeout using epoch comparison (works on all systems).
		if ((start_time > 0)); then
			local now
			now=$(date +%s 2>/dev/null) || now=0
			if (( (now - start_time) >= timeout )); then
				return 1
			fi
		fi

		# Exponential backoff: 10ms → 20ms → 40ms, capped at 100ms to avoid
		# sleeping too long under sustained high contention. Reduces per-second
		# mkdir() attempts from 10/sec (10Hz polling) to ~10-30/sec under load.
		local sleep_ms=$((backoff))
		if ((sleep_ms > 100)); then
			sleep_ms=100
		fi

		# Convert to seconds: `sleep 0.01` is 10ms. Fallback for shells
		# that only accept integer seconds.
		awk -v ms="$sleep_ms" 'BEGIN { printf "%.2f\n", ms/1000 }' | \
			xargs -I {} sleep {} 2>/dev/null || sleep 1

		backoff=$((backoff * 2))
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

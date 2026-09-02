#!/usr/bin/env bash
# Portable advisory file locking via mkdir() atomicity.
#
# This file is VENDORED into the plugins that lock. Edit this canonical copy
# and run scripts/sync-shared-libs.sh to propagate it; drift is caught by
# test/bats/shared-lib-vendoring.bats.
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
#   lock_acquire "/path/to/file.lock" [timeout_seconds=5] [stale_seconds=30]
#   # ... critical section ...
#   lock_release "/path/to/file.lock"
#
# Avoid associative arrays so bash 3.2 (macOS default) keeps working.

# How long a lock with no readable holder may sit before a waiter breaks it.
# Callers override per-call (third argument) or globally via LOCK_STALE_SECONDS.
LOCK_STALE_SECONDS="${LOCK_STALE_SECONDS:-30}"

# Every holder stamps its pid here so a waiter can tell an abandoned lock from
# a slow one. Written after mkdir, so there is a brief window where a held lock
# has no holder file — see _lock_stale for how that is handled.
#
# The pid alone, deliberately: it is the whole staleness signal, and it doubles
# as the token _lock_break verifies against. A wall-clock stamp would add a
# fork to every acquire on a path whose per-hook cost is actively budgeted, to
# record something the file's own mtime already carries. A holder cannot be
# judged stale while it is alive, so the pid that a break decision was made
# against can never come back and retake the lock under the same number.
_lock_write_holder() {
	printf '%s\n' "$$" >"${1}/holder" 2>/dev/null || true
}

# Read the holder pid into _LOCK_HOLDER, or "" when absent or unreadable.
#
# Sets a global instead of echoing because the caller would have to wrap an
# echoing version in $(...), and that command substitution forks a subshell on
# a path that runs on every acquire and every release. `read` from a redirect
# is all builtins, so this costs nothing measurable. Measured: the $(...)
# version added ~3ms to each acquire+release, against a per-edit hook budget
# the rollout tracks in single-digit milliseconds.
_lock_holder() {
	_LOCK_HOLDER=""
	[[ -r "${1}/holder" ]] && read -r _LOCK_HOLDER <"${1}/holder" 2>/dev/null
	return 0
}

# Is a lock held by HOLDER abandoned? WAITED is how long the caller has been
# waiting, used only when there is no holder to interrogate. Takes the holder
# line rather than reading it, so a polling caller pays for one read per
# iteration instead of two.
#
# $$ rather than $BASHPID because bash 3.2 (macOS) has no $BASHPID. Inside a
# subshell that means the holder records its parent's pid, so liveness is
# judged at script granularity — which is the granularity that matters here,
# since it is a killed *hook* the breaker exists to recover from.
_lock_stale() {
	local holder="$1" stale_after="$2" waited="$3"
	local pid

	if [[ -z "$holder" ]]; then
		# No metadata: either the holder was killed between mkdir and its
		# write (microseconds), or it predates this code. Neither is worth
		# breaking on sight, so fall back to the age-based window.
		((waited >= stale_after)) && return 0
		return 1
	fi

	pid="$holder"
	[[ "$pid" =~ ^[0-9]+$ ]] || return 0

	# A live holder is never broken, however long it holds. kill -0 also
	# succeeds for a live process we cannot signal; a recycled pid owned by
	# another user reads as alive, which errs toward leaving the lock alone.
	kill -0 "$pid" 2>/dev/null && return 1
	return 0
}

# Break the lock at LOCKDIR, but only if it still carries the holder line the
# staleness decision was made against.
#
# The move-then-verify dance exists because two waiters can independently
# decide the same lock is stale. Whoever moves it first wins; the loser finds
# a holder line that no longer matches — the winner has already broken and
# retaken the lock — and puts back what it took. Without this, the loser would
# delete the winner's fresh lock and both would believe they hold it.
_lock_break() {
	local lockdir="$1" seen="$2"
	local victim="${lockdir}.stale.$$"

	rm -rf "$victim" 2>/dev/null
	mv "$lockdir" "$victim" 2>/dev/null || return 1

	_lock_holder "$victim"
	if [[ "$_LOCK_HOLDER" != "$seen" ]]; then
		# Put it back, unless a third process has already claimed the path —
		# in which case mv would nest the victim inside it.
		if [[ ! -e "$lockdir" ]] && mv "$victim" "$lockdir" 2>/dev/null; then
			return 1
		fi
		rm -rf "$victim" 2>/dev/null
		return 1
	fi

	rm -rf "$victim" 2>/dev/null
	return 0
}

# Acquire an exclusive lock at LOCKPATH. Returns 0 on success, 1 on timeout.
# Uses exponential backoff under high contention to reduce cache-line thrashing.
lock_acquire() {
	local lockpath="${1:-}"
	local timeout="${2:-5}"
	local stale_after="${3:-$LOCK_STALE_SECONDS}"
	[[ -z "$lockpath" ]] && return 1

	# A stale window longer than the acquire timeout is unsatisfiable: the loop
	# below returns at `waited >= timeout`, so `waited` never reaches a larger
	# stale_after and a holder-less lock can never age into being breakable.
	# The shipped defaults were themselves such a pair (timeout 5, stale 30), so
	# this was not a caller misconfiguration -- every caller taking the defaults
	# inherited a reclamation path that could not fire.
	#
	# That is precisely the lock the reclamation exists for: one abandoned by
	# code that predates holder files, which therefore has no holder to judge.
	# Ten bursar ledgers stopped writing between Jun 20 and Aug 7 waiting on
	# locks this could not break (ecosystem-2vo).
	#
	# Clamping rather than erroring, because breaking at `timeout` is strictly
	# better than the alternative at that instant, which is giving up anyway.
	# The freshness grace period survives -- it just cannot outlast the wait.
	if ((stale_after > timeout)); then
		stale_after="$timeout"
	fi

	local lockdir="${lockpath}.d"
	local start_time
	start_time=$(date +%s 2>/dev/null) || start_time=0

	local backoff=10  # Start at 10ms (1/100s)
	while ! mkdir "$lockdir" 2>/dev/null; do
		# Check timeout using epoch comparison (works on all systems).
		if ((start_time > 0)); then
			local now waited
			now=$(date +%s 2>/dev/null) || now=0
			waited=$((now - start_time))

			# Reclaim an abandoned lock before honoring the timeout: a holder
			# killed by SIGKILL or a harness timeout never runs its EXIT trap,
			# and without this every later caller in that session waits the
			# full timeout and gives up — silently (ecosystem-am1).
			_lock_holder "$lockdir"
			local seen="$_LOCK_HOLDER"
			if _lock_stale "$seen" "$stale_after" "$waited"; then
				_lock_break "$lockdir" "$seen" && continue
			fi

			if ((waited >= timeout)); then
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

	_lock_write_holder "$lockdir"
	return 0
}

# Release the lock previously acquired for LOCKPATH. Safe to call when the
# lock is not held (no-op in that case).
#
# Releases only what this process holds. A lock of ours that went stale and was
# broken and retaken by someone else must survive our late release, or the
# breaker would hand out a lock that its own former owner then evicts.
lock_release() {
	local lockpath="${1:-}"
	[[ -z "$lockpath" ]] && return 0

	local lockdir="${lockpath}.d"
	[[ -d "$lockdir" ]] || return 0

	_lock_holder "$lockdir"
	if [[ -n "$_LOCK_HOLDER" && "$_LOCK_HOLDER" != "$$" ]]; then
		return 0
	fi

	# rm -rf, not rmdir: the holder file lives inside the lock directory.
	rm -rf "$lockdir" 2>/dev/null || true
	return 0
}

#!/usr/bin/env bash
# cartographer-lock.sh — thin wrappers around the shared portable-lock.sh.
#
# portable-lock.sh uses atomic mkdir() which works on Linux, macOS, and any
# POSIX local filesystem without requiring flock or any external utility.
#
# Usage:
#   source cartographer-lock.sh
#   cartographer_lock_acquire <lock_file>   # returns 0=acquired, 1=timeout
#   cartographer_lock_release <lock_file>

# portable-lock.sh is vendored into this plugin's lib dir (a sibling of this
# file) so cartographer stays self-contained when installed standalone from
# the marketplace, where the ecosystem repo's top-level scripts/lib/ is absent.
_CARTOGRAPHER_LOCK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable-lock.sh"

if [[ -f "$_CARTOGRAPHER_LOCK_LIB" ]]; then
	# shellcheck source=./portable-lock.sh
	source "$_CARTOGRAPHER_LOCK_LIB"
else
	# The vendored lock should always be present, but if an unexpected
	# packaging or path issue removes it we must degrade gracefully: the
	# cartographer hooks are fail-soft and contractually exit 0, so a hard
	# exit here would crash a session this plugin was only meant to observe.
	# Define a primitive that always fails to acquire, so the hooks'
	# `cartographer_lock_acquire ... || exit 0` skips the audit instead.
	printf '[cartographer-lock] WARN: portable-lock.sh not found at %s; locking disabled, skipping audit\n' \
		"$_CARTOGRAPHER_LOCK_LIB" >&2
	lock_acquire() { return 1; }
	lock_release() { return 0; }
fi

cartographer_lock_acquire() {
	local lock_file="${1:?lock_file required}"
	mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true
	# Non-blocking: pass timeout=0 so we return immediately if held.
	lock_acquire "$lock_file" 0
}

cartographer_lock_release() {
	local lock_file="${1:?lock_file required}"
	lock_release "$lock_file"
}

# Would a caller be turned away by this lock right now?
#
# Answers by asking the acquire path's own predicate rather than by restating
# one. cartographer_lock_acquire passes timeout=0, which portable-lock clamps
# stale_after down to (portable-lock.sh:140), so "held" here means precisely
# what it means there: a holder _lock_stale refuses to break on the first
# iteration. One definition, consulted twice.
#
# ecosystem-449.62: this was `[[ -d "${lock_file}.d" ]]` alone — a STRICTER rule
# than the lock's. Callers use it to decide whether to start an audit at all,
# and it is the audit's acquire that reclaims abandoned locks, so an existence
# test gated the only code that could clear the lock it was reporting. A lock
# left by a killed audit wedged cartographer permanently: 20 of 23 project
# directories on the author's machine, the oldest stuck since June.
cartographer_lock_is_held() {
	local lock_file="${1:?lock_file required}"
	local lock_dir="${lock_file}.d"
	[[ -d "$lock_dir" ]] || return 1

	# Degraded no-op locking (portable-lock.sh absent). lock_acquire always
	# fails there, so no audit can run whatever we answer; report held so the
	# caller's `is_held && exit 0` skips, matching that contract.
	declare -F _lock_stale >/dev/null 2>&1 || return 0

	# 0 0 = (stale_after, waited), which models cartographer_lock_acquire's loop
	# exactly while that acquire stays non-blocking: timeout=0 clamps stale_after
	# to 0 and the loop runs a single iteration at waited=0. Give the acquire a
	# real timeout and this stops being equivalent — a lock breakable at
	# waited=timeout is not breakable on the first pass — so the two must be
	# changed together.
	_lock_holder "$lock_dir"
	! _lock_stale "$_LOCK_HOLDER" 0 0
}

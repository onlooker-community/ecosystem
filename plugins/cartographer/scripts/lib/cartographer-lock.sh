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

cartographer_lock_is_held() {
	local lock_file="${1:?lock_file required}"
	[[ -d "${lock_file}.d" ]]
}

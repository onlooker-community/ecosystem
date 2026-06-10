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

if [[ ! -f "$_CARTOGRAPHER_LOCK_LIB" ]]; then
	printf '[cartographer-lock] ERROR: portable-lock.sh not found at %s\n' \
		"$_CARTOGRAPHER_LOCK_LIB" >&2
	exit 1
fi

# shellcheck source=./portable-lock.sh
source "$_CARTOGRAPHER_LOCK_LIB"

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

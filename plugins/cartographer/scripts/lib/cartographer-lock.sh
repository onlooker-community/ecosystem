#!/usr/bin/env bash
# cartographer-lock.sh — non-blocking audit lock using flock with PID-file fallback.
#
# flock is preferred (atomic, kernel-level) and available on Linux.
# On macOS without coreutils, an advisory PID file is used instead.
# The fallback has a small TOCTOU window; acceptable for single-machine use.
#
# Usage:
#   source cartographer-lock.sh
#   cartographer_lock_acquire <lock_file>   # returns 0=acquired, 1=already locked
#   cartographer_lock_release <lock_file>

_CARTOGRAPHER_LOCK_FD=9
_CARTOGRAPHER_LOCK_USE_FLOCK=0

cartographer_lock_acquire() {
	local lock_file="${1:?lock_file required}"
	mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

	if command -v flock &>/dev/null; then
		_CARTOGRAPHER_LOCK_USE_FLOCK=1
		eval "exec ${_CARTOGRAPHER_LOCK_FD}>'$lock_file'"
		if flock --nonblock "$_CARTOGRAPHER_LOCK_FD" 2>/dev/null; then
			printf '%d' "$$" >"$lock_file"
			return 0
		else
			eval "exec ${_CARTOGRAPHER_LOCK_FD}>&-"
			return 1
		fi
	fi

	# PID-file fallback
	_CARTOGRAPHER_LOCK_USE_FLOCK=0
	if [[ -f "$lock_file" ]]; then
		local pid
		pid=$(cat "$lock_file" 2>/dev/null)
		if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
			return 1
		fi
		rm -f "$lock_file"
	fi
	printf '%d' "$$" >"$lock_file"
	return 0
}

cartographer_lock_release() {
	local lock_file="${1:?lock_file required}"
	if [[ "$_CARTOGRAPHER_LOCK_USE_FLOCK" -eq 1 ]]; then
		flock --unlock "$_CARTOGRAPHER_LOCK_FD" 2>/dev/null || true
		eval "exec ${_CARTOGRAPHER_LOCK_FD}>&-" 2>/dev/null || true
	fi
	rm -f "$lock_file"
}

cartographer_lock_is_held() {
	local lock_file="${1:?lock_file required}"
	[[ ! -f "$lock_file" ]] && return 1
	local pid
	pid=$(cat "$lock_file" 2>/dev/null)
	[[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

#!/usr/bin/env bash
# cartographer-ulid.sh — ULID generation for Cartographer.
#
# Generates Universally Unique Lexicographically Sortable Identifiers:
# 10-char Crockford Base32 timestamp + 16-char random component = 26 chars.
#
# Usage:
#   id=$(cartographer_ulid)

_CARTOGRAPHER_ULID_ALPHABET="0123456789ABCDEFGHJKMNPQRSTVWXYZ"

_cartographer_ulid_encode() {
	local n="${1:-0}"
	local len="${2:-10}"
	local result=""
	local i
	for (( i = 0; i < len; i++ )); do
		result="${_CARTOGRAPHER_ULID_ALPHABET:$(( n & 31 )):1}${result}"
		n=$(( n >> 5 ))
	done
	printf '%s' "$result"
}

cartographer_ulid() {
	local ts_ms
	# Cheapest clock first (ecosystem-449.20). hook-health.sh ships the full
	# ladder -- $EPOCHREALTIME with no fork, then jq -- and is vendored into
	# every plugin and sourced by every hook before anything else, so it is
	# normally already in scope. The branches below reached straight for
	# python3 on macOS at ~21ms a call; jq answers in ~2.1ms.
	#
	# The jq rung is repeated here rather than delegated because these helpers
	# are also sourced outside hooks (cartographer/scripts/run-audit.sh, the
	# librarian CLI), where hook-health.sh is not loaded.
	if declare -F _hook_health_now_ms >/dev/null 2>&1; then
		ts_ms=$(_hook_health_now_ms)
	elif command -v jq >/dev/null 2>&1 && ts_ms=$(jq -n '(now * 1000 | floor)' 2>/dev/null) \
		&& [[ "${ts_ms}" =~ ^[0-9]{13}$ ]]; then
		: # jq answered
	elif date +%s%3N &>/dev/null && [[ "$(date +%s%3N)" =~ ^[0-9]{13}$ ]]; then
		ts_ms=$(date +%s%3N)
	else
		ts_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
	fi

	local ts_encoded
	ts_encoded=$(_cartographer_ulid_encode "$ts_ms" 10)

	local rand_hex
	rand_hex=$(openssl rand -hex 10 2>/dev/null) \
		|| rand_hex=$(printf '%020x' $(( (RANDOM * RANDOM & 0xFFFFF) * 0x100000 + (RANDOM * RANDOM & 0xFFFFF) )))

	# Bash integers are 63-bit signed, so split the 80-bit random across two 40-bit halves.
	local rand_hi rand_lo
	rand_hi=$(( 16#${rand_hex:0:10} ))
	rand_lo=$(( 16#${rand_hex:10:10} ))
	local rand_encoded
	rand_encoded="$(_cartographer_ulid_encode "$rand_hi" 8)$(_cartographer_ulid_encode "$rand_lo" 8)"

	printf '%s%s' "$ts_encoded" "$rand_encoded"
}

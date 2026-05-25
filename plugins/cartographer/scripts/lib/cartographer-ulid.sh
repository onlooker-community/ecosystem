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
	if date +%s%3N &>/dev/null && [[ "$(date +%s%3N)" =~ ^[0-9]{13}$ ]]; then
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

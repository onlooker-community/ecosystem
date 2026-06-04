#!/usr/bin/env bash
# Minimal ULID generator for Librarian proposal and tombstone IDs.
#
# Spec: https://github.com/ulid/spec
#   - 48-bit timestamp (ms since epoch) → 10 chars Crockford Base32
#   - 80-bit randomness → 16 chars Crockford Base32
#   - lexicographically sortable, time-ordered
#
# Monotonicity across rapid bursts inside a single ms is not required; librarian
# writes proposals at SessionEnd and SessionStart cadence, never in tight loops.

_LIBRARIAN_ULID_ALPHABET="0123456789ABCDEFGHJKMNPQRSTVWXYZ"

# Encode a decimal integer to a fixed-length Crockford Base32 string (uppercase).
# Usage: _librarian_ulid_encode <integer> <length>
_librarian_ulid_encode() {
	local n="$1"
	local len="$2"
	local out=""
	local i
	for ((i = 0; i < len; i++)); do
		out="${_LIBRARIAN_ULID_ALPHABET:$((n % 32)):1}${out}"
		n=$((n / 32))
	done
	printf '%s' "$out"
}

# Generate one ULID. Prints 26 chars (timestamp + randomness).
librarian_ulid() {
	local now_ms
	if [[ "$(uname)" == "Darwin" ]]; then
		now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) \
			|| now_ms=$(($(date +%s) * 1000))
	else
		now_ms=$(date +%s%3N 2>/dev/null) || now_ms=$(($(date +%s) * 1000))
	fi

	local rand_hi rand_lo
	rand_hi=$((RANDOM * 32768 + RANDOM))
	rand_lo=$((RANDOM * 32768 + RANDOM))
	rand_hi=$(((rand_hi * 256 + RANDOM % 256) & ((1 << 40) - 1)))
	rand_lo=$(((rand_lo * 256 + RANDOM % 256) & ((1 << 40) - 1)))

	local ts_part hi_part lo_part
	ts_part=$(_librarian_ulid_encode "$now_ms" 10)
	hi_part=$(_librarian_ulid_encode "$rand_hi" 8)
	lo_part=$(_librarian_ulid_encode "$rand_lo" 8)

	printf '%s%s%s' "$ts_part" "$hi_part" "$lo_part"
}

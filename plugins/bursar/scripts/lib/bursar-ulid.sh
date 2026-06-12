#!/usr/bin/env bash
# Minimal ULID generator for bursar record ids.
#
# Spec: https://github.com/ulid/spec
#   - 48-bit timestamp (ms since epoch) → 10 chars Crockford Base32
#   - 80-bit randomness → 16 chars Crockford Base32
#   - lexicographically sortable, time-ordered
#
# Copied from plugins/tribunal/scripts/lib/tribunal-ulid.sh and renamed; the
# ecosystem ships one *_ulid helper per plugin rather than a shared one.

_BURSAR_ULID_ALPHABET="0123456789ABCDEFGHJKMNPQRSTVWXYZ"

_bursar_ulid_encode() {
	local n="$1"
	local len="$2"
	local out=""
	local i
	for ((i = 0; i < len; i++)); do
		out="${_BURSAR_ULID_ALPHABET:$((n % 32)):1}${out}"
		n=$((n / 32))
	done
	printf '%s' "$out"
}

bursar_ulid() {
	local now_ms
	if [[ "$(uname)" == "Darwin" ]]; then
		now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) \
			|| now_ms=$(($(date +%s) * 1000))
	else
		now_ms=$(date +%s%3N 2>/dev/null) || now_ms=$(($(date +%s) * 1000))
	fi

	local rand_hex rand_hi rand_lo
	rand_hex=$(openssl rand -hex 10 2>/dev/null)
	if [[ -n "$rand_hex" && ${#rand_hex} -eq 20 ]]; then
		rand_hi=$((16#${rand_hex:0:10}))
		rand_lo=$((16#${rand_hex:10:10}))
	else
		rand_hi=$((RANDOM * 32768 + RANDOM))
		rand_lo=$((RANDOM * 32768 + RANDOM))
		rand_hi=$(((rand_hi * 256 + RANDOM % 256) & ((1 << 40) - 1)))
		rand_lo=$(((rand_lo * 256 + RANDOM % 256) & ((1 << 40) - 1)))
	fi

	local ts_part hi_part lo_part
	ts_part=$(_bursar_ulid_encode "$now_ms" 10)
	hi_part=$(_bursar_ulid_encode "$rand_hi" 8)
	lo_part=$(_bursar_ulid_encode "$rand_lo" 8)

	printf '%s%s%s' "$ts_part" "$hi_part" "$lo_part"
}

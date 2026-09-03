#!/usr/bin/env bash
# Minimal ULID generator for Archivist artifact IDs.
#
# Spec: https://github.com/ulid/spec
#   - 48-bit timestamp (ms since epoch) → 10 chars Crockford Base32
#   - 80-bit randomness → 16 chars Crockford Base32
#   - lexicographically sortable, time-ordered
#
# We do not need monotonicity across rapid bursts inside a single ms (the spec's
# optional monotonic mode), since archivist artifacts are written infrequently.

_ARCHIVIST_ULID_ALPHABET="0123456789ABCDEFGHJKMNPQRSTVWXYZ"

# Encode a decimal integer to a fixed-length Crockford Base32 string (uppercase).
# Usage: _archivist_ulid_encode <integer> <length>
_archivist_ulid_encode() {
	local n="$1"
	local len="$2"
	local out=""
	local i
	for ((i = 0; i < len; i++)); do
		out="${_ARCHIVIST_ULID_ALPHABET:$((n % 32)):1}${out}"
		n=$((n / 32))
	done
	printf '%s' "$out"
}

# Generate one ULID. Prints 26 chars (timestamp + randomness).
archivist_ulid() {
	local now_ms
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
		now_ms=$(_hook_health_now_ms)
	elif command -v jq >/dev/null 2>&1 && now_ms=$(jq -n '(now * 1000 | floor)' 2>/dev/null) \
		&& [[ "${now_ms}" =~ ^[0-9]{13}$ ]]; then
		: # jq answered
	elif [[ "$(uname)" == "Darwin" ]]; then
		now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) \
			|| now_ms=$(($(date +%s) * 1000))
	else
		now_ms=$(date +%s%3N 2>/dev/null) || now_ms=$(($(date +%s) * 1000))
	fi

	# 80 bits of randomness, split into two 40-bit halves so we stay inside
	# bash arithmetic (signed 64-bit).
	local rand_hi rand_lo
	rand_hi=$((RANDOM * 32768 + RANDOM))
	rand_lo=$((RANDOM * 32768 + RANDOM))
	rand_hi=$(((rand_hi * 256 + RANDOM % 256) & ((1 << 40) - 1)))
	rand_lo=$(((rand_lo * 256 + RANDOM % 256) & ((1 << 40) - 1)))

	local ts_part hi_part lo_part
	ts_part=$(_archivist_ulid_encode "$now_ms" 10)
	hi_part=$(_archivist_ulid_encode "$rand_hi" 8)
	lo_part=$(_archivist_ulid_encode "$rand_lo" 8)

	printf '%s%s%s' "$ts_part" "$hi_part" "$lo_part"
}

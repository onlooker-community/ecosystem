#!/usr/bin/env bats
#
# The millisecond clock behind ULIDs and inspector's run timing.
#
# ecosystem-449.20. Sixteen files carried a clock that reaches for python3 on
# macOS — either via a `uname == Darwin` branch, or via a `date +%s%3N` probe
# that BSD date answers with a literal "N" (17883932153N), failing the
# 13-digit regex and falling through. Measured at ~21 ms a call, against 2.1 ms
# for `jq -n '(now * 1000 | floor)'` and 0 for $EPOCHREALTIME.
#
# That is not a rounding error on the per-edit budget: inspector-run.sh reads
# the clock five times per checked edit and lineage-post-tool-use.sh mints two
# ULIDs, so a single edit spent ~147 ms asking what time it was.
#
# hook-health.sh already had the correct ladder and is vendored into every
# plugin, so the fix is to use it rather than to write it again sixteen times.
#
# The load-bearing test here is the python3 canary: correctness tests pass
# either way, because the slow path returns the right answer — just slowly.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	CANARY="${BATS_TEST_TMPDIR}/python3_was_called"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	# A python3 that still works, but leaves a fingerprint when used.
	cat >"${STUB_BIN}/python3" <<STUB
#!/usr/bin/env bash
touch "${CANARY}"
exec /usr/bin/env -i PATH="/usr/bin:/bin" python3 "\$@"
STUB
	chmod +x "${STUB_BIN}/python3"
	export PATH="${STUB_BIN}:${PATH}"
}

_plugins_with_ulid() {
	for f in "${REPO_ROOT}"/plugins/*/scripts/lib/*-ulid.sh; do
		basename "$f" -ulid.sh
	done
}

@test "every ULID helper still produces a well-formed ULID" {
	local p f fn out
	for p in $(_plugins_with_ulid); do
		f="${REPO_ROOT}/plugins/${p}/scripts/lib/${p}-ulid.sh"
		fn="${p}_ulid"
		out=$(bash -c "source '${REPO_ROOT}/plugins/${p}/scripts/lib/hook-health.sh' 2>/dev/null; source '$f'; $fn")
		[ "${#out}" -eq 26 ] || { echo "$p produced ${#out} chars: $out"; return 1; }
		[[ "$out" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || { echo "$p produced non-Crockford: $out"; return 1; }
	done
}

# The regression test. Every one of these ran python3 before the fix.
@test "no ULID helper reaches for python3 when a cheaper clock exists" {
	local p f fn
	for p in $(_plugins_with_ulid); do
		f="${REPO_ROOT}/plugins/${p}/scripts/lib/${p}-ulid.sh"
		fn="${p}_ulid"
		rm -f "$CANARY"
		bash -c "source '${REPO_ROOT}/plugins/${p}/scripts/lib/hook-health.sh' 2>/dev/null; source '$f'; $fn" >/dev/null
		[ ! -e "$CANARY" ] || { echo "$p invoked python3 for a timestamp"; return 1; }
	done
}

@test "inspector's run clock does not reach for python3 either" {
	rm -f "$CANARY"
	run bash -c "
		source '${REPO_ROOT}/plugins/inspector/scripts/lib/hook-health.sh' 2>/dev/null
		source '${REPO_ROOT}/plugins/inspector/scripts/lib/inspector-run.sh'
		_inspector_now_ms"
	[ ! -e "$CANARY" ] || { echo "inspector_now_ms invoked python3"; return 1; }
	[[ "$output" =~ ^[0-9]{13}$ ]] || { echo "got: $output"; return 1; }
}

@test "the run clock reports a plausible current time, not a garbage BSD date" {
	local now got skew
	now=$(jq -n '(now * 1000 | floor)')
	got=$(bash -c "
		source '${REPO_ROOT}/plugins/inspector/scripts/lib/hook-health.sh' 2>/dev/null
		source '${REPO_ROOT}/plugins/inspector/scripts/lib/inspector-run.sh'
		_inspector_now_ms")
	# Guards the exact defect: BSD date answers +%s%3N with a trailing literal
	# "N", which is not a number and would have blown up this subtraction.
	skew=$(( got > now ? got - now : now - got ))
	[ "$skew" -lt 60000 ] || { echo "clock off by ${skew}ms (got $got, expected ~$now)"; return 1; }
}

# The helpers are also sourced outside hooks (cartographer/scripts/run-audit.sh,
# the librarian CLI), where hook-health.sh is not in scope. They must still work.
@test "ULID helpers work standalone, without hook-health sourced" {
	local out
	out=$(bash -c "source '${REPO_ROOT}/plugins/inspector/scripts/lib/inspector-ulid.sh'; inspector_ulid")
	[ "${#out}" -eq 26 ]
}

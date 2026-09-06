#!/usr/bin/env bats

# How echo's Stop gate finds the ecosystem substrate when installed as a plugin
# (ecosystem-449.36 and ecosystem-449.35).
#
# Two defects share one five-line glob loop:
#
#   449.36 — the match is .../ecosystem/<v>/scripts/lib/validate-path.sh, and
#     two dirnames strip only lib/ and the filename, landing on .../<v>/scripts.
#     The guard then tests .../<v>/scripts/scripts/lib/validate-path.sh, finds
#     nothing, and the substrate is silently never sourced.
#   449.35 — the loop breaks on the first glob match, and glob expansion is
#     lexicographic rather than semver, so 0.33.1 sorts ahead of 0.49.2.
#
# They have to move together: correcting only the doubling takes echo from
# sourcing nothing to sourcing a month-stale substrate for real.
#
# Measured on a real install, echo resolved to ecosystem 0.33.1 against an
# active 0.49.2, and its guard found nothing — so both defects were live.
#
# The normal suite exports ONLOOKER_ECOSYSTEM_ROOT, which short-circuits this
# branch entirely. That is why a broken resolution had no failing test.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# Deliberately NOT exported — it is the escape hatch this branch backs up,
	# and leaving it set would mean testing nothing.
	unset ONLOOKER_ECOSYSTEM_ROOT

	CACHE="${BATS_TEST_TMPDIR}/cache"
	mkdir -p "${CACHE}/echo"
	cp -R "${REPO_ROOT}/plugins/echo" "${CACHE}/echo-src"
	mv "${CACHE}/echo-src" "${CACHE}/echo/0.4.5"
	HOOK="${CACHE}/echo/0.4.5/scripts/hooks/echo-stop-gate.sh"

	# Two cached ecosystems. 0.33.1 sorts first lexically, 0.49.2 is newest.
	# Each stamps which copy was sourced, making the choice observable.
	MARKER="${BATS_TEST_TMPDIR}/sourced-version"
	for v in 0.33.1 0.49.2; do
		mkdir -p "${CACHE}/ecosystem/${v}/scripts/lib"
		cat > "${CACHE}/ecosystem/${v}/scripts/lib/validate-path.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "${v}" >> "${MARKER}"
STUB
		printf '%s\n' '#!/usr/bin/env bash' > "${CACHE}/ecosystem/${v}/scripts/lib/onlooker-schema.sh"
	done
}

_resolve() {
	# Sourcing happens before the hook does any real work, so an empty payload
	# is enough to drive the branch under test.
	printf '{}' | bash "$HOOK" >/dev/null 2>&1 || true
}

@test "sources the substrate at all when installed as a plugin" {
	_resolve
	[ -f "$MARKER" ]
}

@test "sources the newest cached ecosystem, not the lexically first" {
	_resolve
	[ -f "$MARKER" ] || return 1
	run head -1 "$MARKER"
	[ "$output" = "0.49.2" ]
}

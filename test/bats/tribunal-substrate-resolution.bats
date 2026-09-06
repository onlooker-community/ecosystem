#!/usr/bin/env bats

# How the Stop gate finds the ecosystem substrate when it is installed as a
# plugin (ecosystem-449.36 and ecosystem-449.35).
#
# Two defects live in the same five-line glob loop, and they hide each other:
#
#   449.36 — the match is .../ecosystem/<v>/scripts/lib/validate-path.sh, and
#     two dirnames strip only lib/ and the filename, landing on .../<v>/scripts.
#     The guard then tests .../<v>/scripts/scripts/lib/validate-path.sh, finds
#     nothing, and the substrate is silently never sourced.
#   449.35 — the loop takes the first glob match, and glob expansion is
#     lexicographic rather than semver, so 0.33.1 sorts ahead of 0.49.2.
#
# Fixing only the doubling would make the gate start sourcing a month-stale
# substrate, which is why both are exercised here.
#
# The normal test setup exports ONLOOKER_ECOSYSTEM_ROOT, which short-circuits
# this branch entirely — so these cases build a fake plugin cache instead, with
# the directory shape the real install has.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# Deliberately NOT exported: it is the escape hatch this branch exists to
	# back up, and leaving it set would mean testing nothing.
	unset ONLOOKER_ECOSYSTEM_ROOT

	CACHE="${BATS_TEST_TMPDIR}/cache"
	mkdir -p "$CACHE"

	# The plugin, at the depth an installed plugin sits: <cache>/tribunal/<v>/
	cp -R "${REPO_ROOT}/plugins/tribunal" "${CACHE}/tribunal-src"
	mkdir -p "${CACHE}/tribunal"
	mv "${CACHE}/tribunal-src" "${CACHE}/tribunal/1.3.6"
	HOOK="${CACHE}/tribunal/1.3.6/scripts/hooks/tribunal-stop-gate.sh"

	# Two cached ecosystems. 0.33.1 sorts first lexically, 0.49.2 is newest.
	# Each stamps which copy was sourced, so the choice is observable.
	MARKER="${BATS_TEST_TMPDIR}/sourced-version"
	for v in 0.33.1 0.49.2; do
		mkdir -p "${CACHE}/ecosystem/${v}/scripts/lib"
		cat > "${CACHE}/ecosystem/${v}/scripts/lib/validate-path.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "${v}" >> "${MARKER}"
STUB
		# The gate sources this immediately after validate-path.sh.
		printf '%s\n' '#!/usr/bin/env bash' > "${CACHE}/ecosystem/${v}/scripts/lib/onlooker-schema.sh"
	done
}

_resolve() {
	# Drive only the resolution branch: the gate reads stdin, so feed it an
	# empty payload and let it exit on its own. Sourcing is the side effect
	# under test and happens before any of that.
	printf '{}' | bash "$HOOK" >/dev/null 2>&1 || true
}

@test "sources the substrate at all when installed as a plugin" {
	# 449.36: with two dirnames the guard never matched, so nothing was sourced
	# and ONLOOKER_EVENTS_LOG and friends were never exported.
	_resolve
	[ -f "$MARKER" ]
}

@test "sources the newest cached ecosystem, not the lexically first" {
	# 449.35: glob order puts 0.33.1 first; version order puts 0.49.2 last.
	_resolve
	[ -f "$MARKER" ] || return 1
	run head -1 "$MARKER"
	[ "$output" = "0.49.2" ]
}

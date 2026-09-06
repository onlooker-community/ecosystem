#!/usr/bin/env bats

# How archivist's hooks find the ecosystem substrate when installed as plugins
# (ecosystem-449.36 and ecosystem-449.35).
#
# Two defects share one five-line glob loop, present in BOTH hooks:
#
#   449.36 — the match is .../ecosystem/<v>/scripts/lib/validate-path.sh, and
#     two dirnames strip only lib/ and the filename, landing on .../<v>/scripts.
#     The guard then tests .../<v>/scripts/scripts/lib/validate-path.sh, finds
#     nothing, and the substrate is silently never sourced.
#   449.35 — the loop breaks on the first glob match, and glob expansion is
#     lexicographic rather than semver, so 0.33.1 sorts ahead of 0.49.2.
#
# They move together: correcting only the doubling takes archivist from sourcing
# nothing to sourcing a month-stale substrate for real.
#
# Measured against the real install before this fix: archivist bound ecosystem
# 0.33.1 against an active 0.49.2, and its guard found nothing — so it had been
# running with no substrate at all.
#
# Both hooks are covered because both carry the defect, and a fix applied to one
# would leave the other silently broken.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# Deliberately NOT exported — it is the escape hatch this branch backs up,
	# and leaving it set would short-circuit the code under test.
	unset ONLOOKER_ECOSYSTEM_ROOT

	CACHE="${BATS_TEST_TMPDIR}/cache"
	mkdir -p "${CACHE}/archivist"
	cp -R "${REPO_ROOT}/plugins/archivist" "${CACHE}/archivist-src"
	mv "${CACHE}/archivist-src" "${CACHE}/archivist/0.4.6"
	EXTRACT="${CACHE}/archivist/0.4.6/scripts/hooks/archivist-extract.sh"
	INJECT="${CACHE}/archivist/0.4.6/scripts/hooks/archivist-inject.sh"

	MARKER="${BATS_TEST_TMPDIR}/sourced-version"
	for v in 0.33.1 0.49.2; do
		mkdir -p "${CACHE}/ecosystem/${v}/scripts/lib"
		cat > "${CACHE}/ecosystem/${v}/scripts/lib/validate-path.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "${v}" >> "${MARKER}"
STUB
	done
}

@test "extract sources the substrate at all when installed as a plugin" {
	printf '{}' | bash "$EXTRACT" >/dev/null 2>&1 || true
	[ -f "$MARKER" ]
}

@test "extract sources the newest cached ecosystem, not the lexically first" {
	printf '{}' | bash "$EXTRACT" >/dev/null 2>&1 || true
	[ -f "$MARKER" ] || return 1
	run head -1 "$MARKER"
	[ "$output" = "0.49.2" ]
}

@test "inject sources the substrate at all when installed as a plugin" {
	printf '{}' | bash "$INJECT" >/dev/null 2>&1 || true
	[ -f "$MARKER" ]
}

@test "inject sources the newest cached ecosystem, not the lexically first" {
	printf '{}' | bash "$INJECT" >/dev/null 2>&1 || true
	[ -f "$MARKER" ] || return 1
	run head -1 "$MARKER"
	[ "$output" = "0.49.2" ]
}

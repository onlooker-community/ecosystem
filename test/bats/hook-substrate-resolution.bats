#!/usr/bin/env bats
#
# Guards how hook scripts resolve the ecosystem substrate.
#
# Fifteen hooks across eight plugins each carried their own copy of a five-line
# glob loop that re-derived an ecosystem root from the match with two dirnames.
# The match is .../ecosystem/<v>/scripts/lib/validate-path.sh, so two dirnames
# strip lib/ and the filename and land on .../<v>/scripts. The guard that
# follows tests "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" -- the doubled
# .../<v>/scripts/scripts/lib/validate-path.sh -- finds nothing, and the
# substrate is never sourced (ecosystem-449.36).
#
# Sourcing it is also what exports ONLOOKER_EVENTS_LOG, so the failure lands
# differently per caller. Where the plugin's emit lib defaults its own sink the
# outage is invisible; where it bails on unset -- librarian -- every event is
# dropped in silence. That is why librarian alone went quiet for 34 days while
# archivist, assayer and historian emitted normally through the same defect.
#
# The glob carries a second, independent defect: it takes the first match in
# lexical order, which is not version order (ecosystem-449.35). The fixture
# pins three versions where the two orders disagree in both directions --
# lexically 0.33.1 < 0.49.2 < 0.9.0, but 0.49.2 is highest -- so neither
# `head -1` nor `tail -1` can pass by accident.
#
# Both defects are fixed once, in the vendored ecosystem-root.sh, rather than
# fifteen times in place. The structural test at the bottom is what keeps the
# open-coded shape from coming back.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

# Every plugin that vendors the resolver. Each must carry its own copy: an
# installed plugin is its own tree with no ecosystem checkout above it, which
# is the whole reason these libs are vendored rather than shared.
_resolver_plugins() {
	printf '%s\n' archivist assayer curator echo governor historian librarian tribunal
}

# Build a plugin cache mirroring the real layout:
#
#   <cache>/ecosystem/<v>/scripts/lib/validate-path.sh
#   <cache>/<plugin>/1.0.0/scripts/lib/ecosystem-root.sh
#
# so plugin_root/../../ecosystem/* matches exactly as it does on disk. No
# validate-path.sh is placed at <cache>/scripts/lib, so resolution falls
# through the direct-sibling branch and reaches the glob under test.
_resolve_against_fixture() {
	local plugin="$1"
	local cache="${BATS_TEST_TMPDIR}/cache-${plugin}"
	rm -rf "$cache"

	local v
	for v in 0.9.0 0.33.1 0.49.2; do
		mkdir -p "${cache}/ecosystem/${v}/scripts/lib"
		printf '# ecosystem %s\n' "$v" \
			>"${cache}/ecosystem/${v}/scripts/lib/validate-path.sh"
	done

	mkdir -p "${cache}/${plugin}/1.0.0/scripts/lib"
	cp "${REPO_ROOT}/plugins/${plugin}/scripts/lib/ecosystem-root.sh" \
		"${cache}/${plugin}/1.0.0/scripts/lib/ecosystem-root.sh"

	(
		unset ONLOOKER_ECOSYSTEM_ROOT
		# shellcheck disable=SC1090
		source "${cache}/${plugin}/1.0.0/scripts/lib/ecosystem-root.sh"
		onlooker_ecosystem_root "${cache}/${plugin}/1.0.0"
	)
}

# Without this, a typo in _resolver_plugins would make every test below pass
# over an empty list and report coverage that does not exist.
@test "every plugin named here vendors the resolver" {
	local plugin
	while IFS= read -r plugin; do
		[ -f "${REPO_ROOT}/plugins/${plugin}/scripts/lib/ecosystem-root.sh" ]
	done < <(_resolver_plugins)
	[ "$(_resolver_plugins | wc -l | tr -d ' ')" -eq 8 ]
}

@test "every vendored resolver returns a root whose substrate exists" {
	local plugin resolved offenders=""
	while IFS= read -r plugin; do
		resolved="$(_resolve_against_fixture "$plugin")"
		if [ ! -f "${resolved}/scripts/lib/validate-path.sh" ]; then
			offenders+="${plugin} -> ${resolved}"$'\n'
		fi
	done < <(_resolver_plugins)
	[ -z "$offenders" ] || {
		printf 'root has no substrate beneath it:\n%s' "$offenders" >&2
		return 1
	}
}

@test "every vendored resolver binds the highest version, not the lexically first" {
	local plugin resolved offenders=""
	while IFS= read -r plugin; do
		resolved="$(_resolve_against_fixture "$plugin")"
		case "$resolved" in
		*/ecosystem/0.49.2) ;;
		*) offenders+="${plugin} -> ${resolved}"$'\n' ;;
		esac
	done < <(_resolver_plugins)
	[ -z "$offenders" ] || {
		printf 'expected ecosystem 0.49.2:\n%s' "$offenders" >&2
		return 1
	}
}

# The env override is how the normal suite short-circuits discovery entirely.
# It has to keep winning, or every other bats file that exports it starts
# exercising the glob instead of the checkout it meant to point at.
@test "ONLOOKER_ECOSYSTEM_ROOT wins over discovery" {
	source "${REPO_ROOT}/scripts/lib/ecosystem-root.sh"
	run env ONLOOKER_ECOSYSTEM_ROOT=/pinned bash -c \
		"source '${REPO_ROOT}/scripts/lib/ecosystem-root.sh'; onlooker_ecosystem_root /anywhere"
	[ "$status" -eq 0 ]
	[ "$output" = "/pinned" ]
}

# A plugin installed beside the ecosystem checkout itself, rather than in the
# version-keyed cache. This branch resolved correctly before the fix and must
# keep doing so -- it is what the repo's own test harness relies on.
@test "a direct sibling checkout resolves without consulting the glob" {
	local root="${BATS_TEST_TMPDIR}/sibling"
	rm -rf "$root"
	mkdir -p "${root}/scripts/lib" "${root}/plugins/demo/scripts/lib"
	printf '# substrate\n' >"${root}/scripts/lib/validate-path.sh"
	cp "${REPO_ROOT}/scripts/lib/ecosystem-root.sh" \
		"${root}/plugins/demo/scripts/lib/ecosystem-root.sh"

	run env -u ONLOOKER_ECOSYSTEM_ROOT bash -c \
		"source '${root}/plugins/demo/scripts/lib/ecosystem-root.sh'; onlooker_ecosystem_root '${root}/plugins/demo'"
	[ "$status" -eq 0 ]
	[ "$output" = "$root" ]
}

# Nothing to resolve is a real state, not an error: a plugin installed with no
# ecosystem anywhere above it must yield empty and let the caller's own guard
# skip the source. Emitting a path that does not exist is what the doubled
# derivation did, and the caller's -f guard is the only thing that caught it.
@test "resolution yields empty when no substrate exists anywhere" {
	local root="${BATS_TEST_TMPDIR}/orphan"
	rm -rf "$root"
	mkdir -p "${root}/demo/1.0.0/scripts/lib"
	cp "${REPO_ROOT}/scripts/lib/ecosystem-root.sh" \
		"${root}/demo/1.0.0/scripts/lib/ecosystem-root.sh"

	run env -u ONLOOKER_ECOSYSTEM_ROOT bash -c \
		"source '${root}/demo/1.0.0/scripts/lib/ecosystem-root.sh'; onlooker_ecosystem_root '${root}/demo/1.0.0'"
	[ -z "$output" ]
}

# A plugin root that does not exist at all, which makes the `cd` itself fail
# rather than merely find nothing. Same contract: empty, and no stray path or
# error text on stdout for the caller to mistake for a root.
@test "resolution yields empty when the plugin root does not exist" {
	run env -u ONLOOKER_ECOSYSTEM_ROOT bash -c \
		"source '${REPO_ROOT}/scripts/lib/ecosystem-root.sh'; onlooker_ecosystem_root '${BATS_TEST_TMPDIR}/no/such/plugin'"
	[ -z "$output" ]
}

# The behavioral tests above prove resolution is correct today. This one stops
# the open-coded shape from coming back in a hook the fixture forgot -- which
# is exactly how fifteen copies of it accumulated.
@test "no hook re-derives an ecosystem root from a glob match" {
	local hits
	hits=$(cd "$REPO_ROOT" && grep -rn 'dirname "\$(dirname "\$_candidate")"' \
		--include="*.sh" plugins/ || true)
	[ -z "$hits" ] || {
		printf 'hook re-derives a root by nested dirname:\n%s\n' "$hits" >&2
		return 1
	}
}

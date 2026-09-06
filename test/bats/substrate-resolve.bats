#!/usr/bin/env bats

# The shared substrate resolver (ecosystem-449.36, ecosystem-449.35).
#
# Fourteen hooks each carried a byte-identical copy of this lookup, wrong the
# same two ways in all fourteen:
#
#   449.36 — two dirnames instead of three. The match is
#     .../ecosystem/<v>/scripts/lib/validate-path.sh, so stripping only lib/ and
#     the filename lands on .../<v>/scripts; every caller then tested
#     .../<v>/scripts/scripts/lib/validate-path.sh and found nothing. Sourcing
#     the substrate is what exports ONLOOKER_EVENTS_LOG, so the miss was silent
#     in both directions.
#   449.35 — first glob match rather than newest. Glob expansion is
#     lexicographic, not semver, so 0.33.1 sorted ahead of 0.49.2.
#
# The second half of this file sweeps EVERY hook that resolves the substrate
# rather than testing a chosen few, because "fixed in some of the copies" is the
# exact state this refactor exists to make impossible.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# The override short-circuits resolution, so it must be off for every case
	# here except the one that tests the override itself.
	unset ONLOOKER_ECOSYSTEM_ROOT

	CACHE="${BATS_TEST_TMPDIR}/cache"
	MARKER="${BATS_TEST_TMPDIR}/sourced-version"
}

# Build a fake plugin cache: <cache>/<plugin>/<version>/ beside
# <cache>/ecosystem/{0.33.1,0.49.2}/, the shape a real install has.
_fake_cache() {
	local plugin="$1"
	mkdir -p "${CACHE}/${plugin}"
	cp -R "${REPO_ROOT}/plugins/${plugin}" "${CACHE}/${plugin}-src"
	mv "${CACHE}/${plugin}-src" "${CACHE}/${plugin}/9.9.9"
	local v
	for v in 0.33.1 0.49.2; do
		mkdir -p "${CACHE}/ecosystem/${v}/scripts/lib"
		cat > "${CACHE}/ecosystem/${v}/scripts/lib/validate-path.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "${v}" >> "${MARKER}"
STUB
		printf '%s\n' '#!/usr/bin/env bash' > "${CACHE}/ecosystem/${v}/scripts/lib/onlooker-schema.sh"
	done
	printf '%s' "${CACHE}/${plugin}/9.9.9"
}

# ---------------------------------------------------------------------------
# The resolver itself
# ---------------------------------------------------------------------------

@test "resolves the newest cached ecosystem, not the lexically first" {
	local root
	root=$(_fake_cache lineage)
	# shellcheck disable=SC1091
	source "${root}/scripts/lib/substrate-resolve.sh"
	run onlooker_resolve_substrate "$root"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"/ecosystem/0.49.2" ]]
}

@test "resolves to a directory that actually contains the substrate" {
	# The 449.36 half: the returned root must satisfy the guard every caller
	# applies to it, which the doubled path never did.
	local root
	root=$(_fake_cache lineage)
	# shellcheck disable=SC1091
	source "${root}/scripts/lib/substrate-resolve.sh"
	local resolved
	resolved=$(onlooker_resolve_substrate "$root")
	[ -f "${resolved}/scripts/lib/validate-path.sh" ]
}

@test "an explicit ONLOOKER_ECOSYSTEM_ROOT wins over the cache" {
	local root
	root=$(_fake_cache lineage)
	# shellcheck disable=SC1091
	source "${root}/scripts/lib/substrate-resolve.sh"
	ONLOOKER_ECOSYSTEM_ROOT="/explicit/override" run onlooker_resolve_substrate "$root"
	[ "$output" = "/explicit/override" ]
}

@test "returns nothing rather than failing when no ecosystem is present" {
	# Hooks treat an empty root as "no substrate" and carry on; a non-zero exit
	# under `set -e` would turn a soft skip into a dead hook.
	local bare="${BATS_TEST_TMPDIR}/bare/plugin/1.0.0"
	mkdir -p "$bare"
	cp "${REPO_ROOT}/scripts/lib/substrate-resolve.sh" "${bare}/substrate-resolve.sh"
	# shellcheck disable=SC1091
	source "${bare}/substrate-resolve.sh"
	run onlooker_resolve_substrate "$bare"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "works from a plugin tree copied outside the repo" {
	# Vendoring exists so an installed plugin, which has no ecosystem checkout
	# above it, can still resolve (ecosystem-ber).
	local standalone="${BATS_TEST_TMPDIR}/standalone"
	mkdir -p "$standalone"
	cp -R "${REPO_ROOT}/plugins/tribunal/scripts" "${standalone}/scripts"
	run bash -c "source '${standalone}/scripts/lib/substrate-resolve.sh'; onlooker_resolve_substrate '${standalone}'"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Every caller, swept
# ---------------------------------------------------------------------------

_hooks_using_resolver() {
	grep -rl 'onlooker_resolve_substrate' "${REPO_ROOT}"/plugins/*/scripts/hooks/*.sh | sort
}

@test "the sweep finds the callers it claims to cover" {
	# Guards the two sweeps below: if the grep stops matching, they would pass
	# by iterating over nothing.
	local count
	count=$(_hooks_using_resolver | wc -l | tr -d ' ')
	[ "$count" -ge 14 ]
}

@test "no hook still carries its own inline substrate lookup" {
	local leftovers
	leftovers=$(grep -rln 'ecosystem/"\*/scripts/lib/validate-path.sh' \
		"${REPO_ROOT}"/plugins/*/scripts/hooks/*.sh 2>/dev/null || true)
	[ -z "$leftovers" ] || { echo "still inline: $leftovers"; return 1; }
}

@test "every hook that resolves the substrate sources the newest one" {
	# Drives each hook for real from a fake cache, rather than trusting that a
	# shared function is reached the same way everywhere.
	local failures="" hook plugin root rel
	while IFS= read -r hook; do
		rel="${hook#"${REPO_ROOT}/plugins/"}"
		plugin="${rel%%/*}"
		rm -rf "$CACHE" "$MARKER"
		root=$(_fake_cache "$plugin")
		printf '{}' | bash "${root}/scripts/hooks/$(basename "$hook")" >/dev/null 2>&1 || true
		if [[ ! -f "$MARKER" ]]; then
			failures+="${plugin}/$(basename "$hook"):never-sourced "
		elif [[ "$(head -1 "$MARKER")" != "0.49.2" ]]; then
			failures+="${plugin}/$(basename "$hook"):$(head -1 "$MARKER") "
		fi
	done < <(_hooks_using_resolver)
	[ -z "$failures" ] || { echo "failed: $failures"; return 1; }
}

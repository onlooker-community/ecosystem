#!/usr/bin/env bats

# Both shared libs are vendored per plugin rather than shared, because an
# installed plugin is its own tree with no ecosystem checkout above it
# (ecosystem-ber). Vendoring only works if the copies stay identical.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

_plugin_dirs() {
	find "${REPO_ROOT}/plugins" -maxdepth 1 -mindepth 1 -type d | sort
}

@test "the plugin glob matches at least one plugin" {
	local count
	count=$(_plugin_dirs | wc -l | tr -d ' ')
	[ "$count" -gt 0 ]
}

# Read the list from the sync script rather than repeating it here, so adding a
# lib to SHARED_LIBS cannot leave it silently unguarded — which is the failure
# mode that let substrate-resolve.sh's predecessor rot in fourteen copies.
_shared_libs() {
	sed -n 's/^SHARED_LIBS=(\(.*\))$/\1/p' "${REPO_ROOT}/scripts/sync-shared-libs.sh" | tr ' ' '\n'
}

@test "the shared-lib list is readable and non-empty" {
	local count
	count=$(_shared_libs | grep -c .)
	[ "$count" -gt 0 ]
}

@test "every plugin has a vendored copy of every shared lib" {
	local missing="" lib d
	while IFS= read -r lib; do
		[ -n "$lib" ] || continue
		while IFS= read -r d; do
			[ -f "${d}/scripts/lib/${lib}" ] || missing+="$(basename "$d")/${lib} "
		done < <(_plugin_dirs)
	done < <(_shared_libs)
	[ -z "$missing" ] || { echo "missing: $missing"; return 1; }
}

@test "every vendored shared lib is byte-identical to its canonical copy" {
	local drifted="" lib d
	while IFS= read -r lib; do
		[ -n "$lib" ] || continue
		while IFS= read -r d; do
			cmp -s "${REPO_ROOT}/scripts/lib/${lib}" "${d}/scripts/lib/${lib}" \
				|| drifted+="$(basename "$d")/${lib} "
		done < <(_plugin_dirs)
	done < <(_shared_libs)
	[ -z "$drifted" ] || { echo "drifted: $drifted"; return 1; }
}

@test "the sync script reports no drift" {
	run "${REPO_ROOT}/scripts/sync-shared-libs.sh" --check
	[ "$status" -eq 0 ]
}

@test "hook-health works from a plugin tree copied outside the repo" {
	local standalone="${BATS_TEST_TMPDIR}/standalone"
	mkdir -p "$standalone"
	cp -R "${REPO_ROOT}/plugins/lineage/scripts" "${standalone}/scripts"
	run bash -c "
		source '${standalone}/scripts/lib/hook-health.sh'
		export ONLOOKER_HOOK_HEALTH_LOG='${ONLOOKER_DIR}/logs/hook-health.jsonl'
		hook_health_register 'standalone-hook'
		exit 0
	"
	[ "$status" -eq 0 ] || return 1
	tail -n 1 "${ONLOOKER_DIR}/logs/hook-health.jsonl" \
		| jq -e '.hook == "standalone-hook"' >/dev/null
}

# ON_DEMAND_LIBS are vendored only where a copy already exists, rather than
# into every plugin: only a few plugins lock or watch anything. portable-lock.sh
# went unsynced for long enough that governor, cartographer, and lineage were
# all running a superseded generation of lock_acquire (ecosystem-am1).
#
# Read from the sync script for the same reason _shared_libs does, so adding a
# lib to ON_DEMAND_LIBS cannot leave it silently unguarded. watch-unmatched.sh
# was added to that list with no guard covering it at all (ONL-66).
_on_demand_libs() {
	sed -n 's/^ON_DEMAND_LIBS=(\(.*\))$/\1/p' "${REPO_ROOT}/scripts/sync-shared-libs.sh" | tr ' ' '\n'
}

@test "the on-demand lib list is readable and non-empty" {
	local count
	count=$(_on_demand_libs | grep -c .)
	[ "$count" -gt 0 ]
}

@test "every plugin that sources an on-demand lib vendors a copy of it" {
	local missing="" lib d
	while IFS= read -r lib; do
		[ -n "$lib" ] || continue
		# Built by concatenation, not interpolated into a double-quoted
		# string: there, bash collapses \$ to a bare $, which ERE then reads
		# as end-of-line, and the pattern silently matches nothing.
		# Dots in the lib name are escaped so they are not ERE wildcards.
		local pat
		pat='(^|[[:space:]])(\.|source)[[:space:]]+"\$\{?PLUGIN_ROOT\}?/scripts/lib/'"${lib//./\\.}"'"'
		while IFS= read -r d; do
			grep -rqE "$pat" "${d}/scripts" 2>/dev/null || continue
			[ -f "${d}/scripts/lib/${lib}" ] || missing+="$(basename "$d")/${lib} "
		done < <(_plugin_dirs)
	done < <(_on_demand_libs)
	[ -z "$missing" ] || { echo "sources it but does not vendor it: $missing"; return 1; }
}

@test "every vendored on-demand lib is byte-identical to its canonical copy" {
	local drifted="" lib d
	while IFS= read -r lib; do
		[ -n "$lib" ] || continue
		while IFS= read -r d; do
			[ -f "${d}/scripts/lib/${lib}" ] || continue
			cmp -s "${REPO_ROOT}/scripts/lib/${lib}" "${d}/scripts/lib/${lib}" \
				|| drifted+="$(basename "$d")/${lib} "
		done < <(_plugin_dirs)
	done < <(_on_demand_libs)
	[ -z "$drifted" ] || { echo "drifted: $drifted"; return 1; }
}

# The guard sync-shared-libs.sh's header has always claimed, and which did not
# exist for anything but portable-lock.sh (ONL-66). It covers every lib a hook
# sources from its OWN tree, whichever list the lib is on and even if it is on
# neither — a plugin-local lib counts too.
#
# Why it matters more than the list-driven tests above: a shared lib lands
# everywhere automatically, so a missing copy is already impossible. An
# on-demand lib is adopted by hand, and that is exactly where someone adds the
# source line and forgets the copy. The failure is silent at runtime — the
# source fails, every accessor is undefined, and the hook still exits 0
# (CLAUDE.md item 8).
#
# $PLUGIN_ROOT paths only. A hook may legitimately source the substrate via
# ${_ECOSYSTEM_ROOT}/scripts/lib/..., which the plugin must NOT vendor, so
# anchoring on PLUGIN_ROOT is what keeps that out of the results. Libs sourced
# through a BASH_SOURCE-relative variable are a different mechanism, covered by
# config-lib-self-locating.bats.
_libs_sourced_from_own_tree() {
	local dir="$1"
	grep -rhoE '(^|[[:space:]])(\.|source)[[:space:]]+"\$\{?PLUGIN_ROOT\}?/scripts/lib/[A-Za-z0-9._-]+\.sh"' \
		"${dir}/scripts" 2>/dev/null \
		| grep -oE '[A-Za-z0-9._-]+\.sh' | sort -u
}

@test "every plugin vendors every lib it sources from its own tree" {
	local missing="" checked=0 d lib
	while IFS= read -r d; do
		while IFS= read -r lib; do
			[ -n "$lib" ] || continue
			checked=$((checked + 1))
			[ -f "${d}/scripts/lib/${lib}" ] || missing+="$(basename "$d")/${lib} "
		done < <(_libs_sourced_from_own_tree "$d")
	done < <(_plugin_dirs)

	# A regex that silently matches nothing would make this test vacuous, which
	# is the shape of the bug it exists to prevent.
	[ "$checked" -gt 0 ] || { echo "matched no source lines at all"; return 1; }
	[ -z "$missing" ] || { echo "sources it but does not vendor it: $missing"; return 1; }
}

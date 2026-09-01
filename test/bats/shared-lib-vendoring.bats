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

@test "every plugin has a vendored hook-health.sh" {
	local missing=""
	local d
	while IFS= read -r d; do
		[ -f "${d}/scripts/lib/hook-health.sh" ] || missing+="$(basename "$d") "
	done < <(_plugin_dirs)
	[ -z "$missing" ] || { echo "missing in: $missing"; return 1; }
}

@test "every vendored hook-health.sh is byte-identical to the canonical copy" {
	local canonical="${REPO_ROOT}/scripts/lib/hook-health.sh"
	local drifted=""
	local d
	while IFS= read -r d; do
		cmp -s "$canonical" "${d}/scripts/lib/hook-health.sh" \
			|| drifted+="$(basename "$d") "
	done < <(_plugin_dirs)
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

# portable-lock.sh is vendored on demand rather than into every plugin: only
# four plugins lock anything. It went unsynced for long enough that governor,
# cartographer, and lineage were all running a superseded generation of
# lock_acquire (ecosystem-am1) — these two tests are what would have caught it.

_plugins_sourcing_portable_lock() {
	local d
	while IFS= read -r d; do
		grep -rlE '^[[:space:]]*(\.|source)[[:space:]].*portable-lock\.sh' \
			"${d}/scripts" >/dev/null 2>&1 && basename "$d"
	done < <(_plugin_dirs)
}

@test "every plugin that sources portable-lock.sh vendors a copy of it" {
	local missing="" name
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		[ -f "${REPO_ROOT}/plugins/${name}/scripts/lib/portable-lock.sh" ] \
			|| missing+="$name "
	done < <(_plugins_sourcing_portable_lock)
	[ -z "$missing" ] || { echo "sources it but does not vendor it: $missing"; return 1; }
}

@test "every vendored portable-lock.sh is byte-identical to the canonical copy" {
	local canonical="${REPO_ROOT}/scripts/lib/portable-lock.sh"
	local drifted="" d
	while IFS= read -r d; do
		[ -f "${d}/scripts/lib/portable-lock.sh" ] || continue
		cmp -s "$canonical" "${d}/scripts/lib/portable-lock.sh" \
			|| drifted+="$(basename "$d") "
	done < <(_plugin_dirs)
	[ -z "$drifted" ] || { echo "drifted: $drifted"; return 1; }
}

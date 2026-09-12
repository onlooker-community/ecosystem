#!/usr/bin/env bats
# Probe cache and the age rule (ecosystem-449.59).
#
# The invariant under test: absence of a finding in an EXPIRED cache is not
# evidence of currency. Every is_fresh case below exists so that a future
# change which drops the age comparison fails loudly rather than silently
# reporting a stale answer as a current one.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
	source "${REPO_ROOT}/scripts/lib/plugin-currency-cache.sh"
	CACHE="${BATS_TEST_TMPDIR}/probe.json"
}

@test "a missing cache is not fresh" {
	! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
	[ -z "$(plugin_currency_cache_age_seconds "$CACHE")" ]
}

@test "a just-written cache is fresh" {
	plugin_currency_cache_write "$CACHE" '[]'
	plugin_currency_cache_is_fresh "$CACHE" 6
}

@test "a cache older than the ttl is not fresh" {
	jq -n --arg t "$(relative_iso_days_ago 1)" \
		'{checked_at: $t, findings: []}' >"$CACHE"
	! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
}

@test "an unparseable cache is not fresh" {
	printf 'not json' >"$CACHE"
	! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
}

@test "a cache with no checked_at is not fresh" {
	jq -n '{findings: []}' >"$CACHE"
	! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
}

@test "a cache with an unparseable checked_at is not fresh" {
	jq -n '{checked_at: "last tuesday", findings: []}' >"$CACHE"
	! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
}

@test "age is reported in seconds and reflects the fixture's age" {
	jq -n --arg t "$(relative_iso_days_ago 1)" \
		'{checked_at: $t, findings: []}' >"$CACHE"
	age=$(plugin_currency_cache_age_seconds "$CACHE")
	[ "$age" -gt 80000 ] || return 1
	[ "$age" -lt 90000 ]
}

@test "a ttl boundary is honored: 23h old is stale at ttl 6 but fresh at ttl 24" {
	jq -n --arg t "$(relative_iso_days_ago 1)" \
		'{checked_at: $t, findings: []}' >"$CACHE"
	! plugin_currency_cache_is_fresh "$CACHE" 6 || return 1
	plugin_currency_cache_is_fresh "$CACHE" 25
}

@test "write stamps checked_at and preserves the findings verbatim" {
	plugin_currency_cache_write "$CACHE" \
		'[{"reason":"clone_behind","subject":"onlooker-community"}]'
	jq -e '.checked_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$CACHE" >/dev/null || return 1
	jq -e '.findings[0].reason == "clone_behind"' "$CACHE" >/dev/null || return 1
	jq -e '.findings[0].subject == "onlooker-community"' "$CACHE" >/dev/null
}

@test "write creates the parent directory" {
	local nested="${BATS_TEST_TMPDIR}/a/b/c/probe.json"
	plugin_currency_cache_write "$nested" '[]'
	[ -f "$nested" ]
}

@test "the cache path is project-keyed and lives under ONLOOKER_DIR" {
	local p
	p=$(plugin_currency_cache_path "deadbeef1234")
	[[ "$p" == "${ONLOOKER_DIR}/"* ]] || return 1
	[[ "$p" == *"deadbeef1234"* ]] || return 1
	[[ "$p" == *"probe.json" ]]
}

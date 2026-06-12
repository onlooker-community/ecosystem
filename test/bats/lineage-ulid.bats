#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-ulid.sh"
}

@test "lineage_ulid is 26 characters" {
	run lineage_ulid
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 26 ]
}

@test "lineage_ulid uses only Crockford base32 (no I, L, O, U)" {
	run lineage_ulid
	[[ "$output" =~ ^[0-9A-HJKMNP-TV-Z]+$ ]]
}

@test "two ulids differ" {
	local a b
	a=$(lineage_ulid)
	b=$(lineage_ulid)
	[ "$a" != "$b" ]
}

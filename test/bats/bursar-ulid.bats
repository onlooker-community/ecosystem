#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/bursar-ulid.sh"
}

@test "bursar_ulid is 26 characters" {
	run bursar_ulid
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 26 ]
}

@test "bursar_ulid uses only Crockford base32 (no I, L, O, U)" {
	run bursar_ulid
	[[ "$output" =~ ^[0-9A-HJKMNP-TV-Z]+$ ]]
}

@test "two ulids differ" {
	local a b
	a=$(bursar_ulid)
	b=$(bursar_ulid)
	[ "$a" != "$b" ]
}

#!/usr/bin/env bats

# Exercises the Assayer ULID generator.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-ulid.sh"
}

@test "ulid is 26 chars of Crockford Base32" {
	run assayer_ulid
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 26 ]
	[[ "$output" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]
}

@test "ulids are unique across calls" {
	a=$(assayer_ulid)
	b=$(assayer_ulid)
	[ "$a" != "$b" ]
}

@test "ulids are lexicographically time-ordered" {
	a=$(assayer_ulid)
	sleep 0.01
	b=$(assayer_ulid)
	[[ "$a" < "$b" || "$a" == "$b" ]]
}

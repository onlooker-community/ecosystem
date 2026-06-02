#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/warden"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/warden-ulid.sh"
}

@test "ulid is 26 chars" {
	run warden_ulid
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 26 ]
}

@test "ulid uses only Crockford Base32 characters" {
	run warden_ulid
	[[ "$output" =~ ^[0-9ABCDEFGHJKMNPQRSTVWXYZ]+$ ]]
}

@test "ulids are time-ordered (lexicographically sortable)" {
	local a b
	a=$(warden_ulid)
	sleep 0.01
	b=$(warden_ulid)
	[ "$a" != "$b" ]
	[ "$a" \< "$b" ]
}

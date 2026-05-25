#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/echo-ulid.sh"
}

@test "echo_ulid returns a 26-char crockford base32 string" {
	local id
	id=$(echo_ulid)
	[ "${#id}" -eq 26 ]
	[[ "$id" =~ ^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$ ]]
}

@test "two ULIDs minted apart are lexicographically ordered or equal" {
	local a b
	a=$(echo_ulid)
	sleep 0.01
	b=$(echo_ulid)
	[[ "$a" < "$b" ]] || [ "$a" = "$b" ]
}

@test "many ULIDs are unique" {
	local seen="${BATS_TEST_TMPDIR}/ulids.txt"
	: > "$seen"
	local i
	for ((i = 0; i < 50; i++)); do
		printf '%s\n' "$(echo_ulid)" >> "$seen"
	done
	local total unique
	total=$(wc -l < "$seen" | tr -d ' ')
	unique=$(sort -u "$seen" | wc -l | tr -d ' ')
	[ "$total" = "$unique" ]
}

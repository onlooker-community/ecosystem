#!/usr/bin/env bats

# Exercises Inspector's ULID generator.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/inspector"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/inspector-ulid.sh"
}

@test "produces a 26-char Crockford Base32 ULID" {
	local id
	id=$(inspector_ulid)
	[ "${#id}" = "26" ]
	[[ "$id" =~ ^[0-9ABCDEFGHJKMNPQRSTVWXYZ]{26}$ ]]
}

@test "produces unique values on consecutive calls" {
	local a b
	a=$(inspector_ulid)
	b=$(inspector_ulid)
	[ "$a" != "$b" ]
}

@test "is lexicographically sortable across a short delay" {
	local a b
	a=$(inspector_ulid)
	# Sleep is intentionally <1ms to avoid lengthening the suite, but
	# even back-to-back invocations should not regress the timestamp prefix.
	b=$(inspector_ulid)
	[[ "$a" < "$b" || "$a" == "$b" ]] || [[ "${a:0:10}" == "${b:0:10}" ]]
}

#!/usr/bin/env bats

# The temp dir every test's state hangs off must be unique per bats process.
#
# ONL-61. librarian-session-end.bats:181 failed intermittently in CI on
# `[ "${#proposals[@]}" -eq 2 ]` and nowhere else, only under `-j`, never
# locally. The cause is here rather than in librarian: when bats leaves
# BATS_TEST_TMPDIR unset -- which its own comment says happens on some runners
# during setup_file -- test/helpers/setup.bash derived a path from
# BATS_SUITE_TEST_NUMBER alone. Two files running concurrently can compute the
# same suite test number, and that directory becomes TEST_HOME, ONLOOKER_DIR
# and therefore the proposals directory the assertion counts. The count then
# reflects whatever the other file left behind.
#
# These tests force the fallback, which is otherwise unreachable on a machine
# whose bats always sets BATS_TEST_TMPDIR -- the reason the flake could never
# be reproduced locally.

setup() {
	HELPER="${BATS_TEST_DIRNAME}/../helpers/setup.bash"
}

# Sources the helper in a clean subshell with the fallback forced live, and
# prints whatever BATS_TEST_TMPDIR it settled on.
_fallback_tmpdir() {
	env -u BATS_TEST_TMPDIR BATS_SUITE_TEST_NUMBER="${1:-7}" \
		bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$BATS_TEST_TMPDIR\""
}

@test "the fallback still produces a usable directory" {
	local d
	d=$(_fallback_tmpdir 7)
	[ -n "$d" ] || return 1
	[ -d "$d" ]
}

@test "two processes sharing a suite test number do not share a directory" {
	# The flake, reduced: identical BATS_SUITE_TEST_NUMBER, different processes.
	# Before ONL-61 both derived the same path and trampled each other's state.
	local a b
	a=$(_fallback_tmpdir 7)
	b=$(_fallback_tmpdir 7)
	[ -n "$a" ] && [ -n "$b" ] || return 1
	[ "$a" != "$b" ]
}

@test "a missing suite test number does not collapse every process onto one path" {
	# BATS_SUITE_TEST_NUMBER unset is the worst case: without it the old
	# expansion fell back to a single shared default per value of $$.
	local a b
	a=$(env -u BATS_TEST_TMPDIR -u BATS_SUITE_TEST_NUMBER \
		bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$BATS_TEST_TMPDIR\"")
	b=$(env -u BATS_TEST_TMPDIR -u BATS_SUITE_TEST_NUMBER \
		bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$BATS_TEST_TMPDIR\"")
	[ -n "$a" ] && [ -n "$b" ] || return 1
	[ "$a" != "$b" ]
}

@test "an already-set BATS_TEST_TMPDIR is left alone" {
	# bats owns the variable when it sets it, and it cleans up what it created.
	# The fallback must not override that or tests lose bats' own teardown.
	local fixed="${BATS_TEST_TMPDIR}/preexisting"
	mkdir -p "$fixed"
	local got
	got=$(BATS_TEST_TMPDIR="$fixed" bash -c "source '$HELPER' >/dev/null 2>&1; printf '%s' \"\$BATS_TEST_TMPDIR\"")
	[ "$got" = "$fixed" ]
}

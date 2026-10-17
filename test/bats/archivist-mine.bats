#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	source "${PLUGIN_ROOT}/scripts/lib/archivist-ulid.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-mine.sh"
}

# Records come back NUL-separated because every message contains newlines.
# Read them into an array rather than through bats's `run`, whose command
# substitution strips NUL bytes and would make every split look like one record.
# Sets RECORDS. A nameref would be tidier but needs bash 4.3, and this suite
# has to run on the macOS system bash. The `|| [[ -n "$rec" ]]` picks up the
# final record, which carries no trailing separator.
split_into() {
	RECORDS=()
	local rec
	while IFS= read -r -d '' rec || [[ -n "$rec" ]]; do
		RECORDS+=("$rec")
		rec=""
	done < <(archivist_mine_split "$1")
}

@test "a bulletless body is one message" {
	# A single-commit pull request squashes to its body verbatim, with no
	# bullet at all - measured on 17ae546 in the onlooker repo.
	split_into "Fixed the thing.

Because the old path dropped events."
	[ "${#RECORDS[@]}" -eq 1 ]
	[[ "${RECORDS[0]}" == "Fixed the thing."* ]]
}

@test "a squashed body splits on its bullets" {
	# GitHub concatenates every message behind "* " when a pull request has
	# more than one commit - measured on 4e198fa, eleven of them.
	split_into "* first subject

first body because reasons

* second subject

second body because other reasons"
	[ "${#RECORDS[@]}" -eq 2 ]
	# Normalized on the way out, so each record reads as the message its
	# author wrote rather than as a bullet in someone else's list.
	[[ "${RECORDS[0]}" == "first subject"* ]]
	[[ "${RECORDS[1]}" == "second subject"* ]]
	[[ "${RECORDS[0]}" == *"first body because reasons"* ]]
}

@test "normalizing strips the bullet so both sources agree" {
	# The whole point of content addressing: a message read from the branch
	# commit that wrote it and from the squash that later carried it must hash
	# the same, and the bullet is the only difference between them.
	local from_branch from_squash
	from_branch=$(archivist_mine_normalize "subject line

body because reasons")
	from_squash=$(archivist_mine_normalize "* subject line

body because reasons")
	[ "$from_branch" = "$from_squash" ]
}

@test "normalizing strips a squash-appended pull request number" {
	# GitHub appends " (#123)" to the SUBJECT when it squash-merges, so the
	# message read off the squash differs from the branch commit's by exactly
	# that suffix. The bullet is stripped for this same reason one line up; the
	# number has to go the same way or the digest differs and content
	# addressing buys nothing (ONL-169).
	local from_branch from_squash
	from_branch=$(archivist_mine_normalize "subject line

body because reasons")
	from_squash=$(archivist_mine_normalize "subject line (#450)

body because reasons")
	[ "$from_branch" = "$from_squash" ]
}

@test "normalizing leaves a pull request number inside the body alone" {
	# Only the subject's trailing suffix is squash noise. A number referenced
	# in prose is content, and stripping it would make two different messages
	# hash the same.
	local a b
	a=$(archivist_mine_normalize "subject line

reverts the change from (#450)")
	b=$(archivist_mine_normalize "subject line

reverts the change from (#451)")
	[ "$a" != "$b" ]
}

@test "normalizing trims trailing whitespace" {
	local a b
	a=$(archivist_mine_normalize "subject because reasons")
	b=$(archivist_mine_normalize "subject because reasons

")
	[ "$a" = "$b" ]
}

@test "the id is a well-formed ULID" {
	run archivist_mine_id "subject because reasons"
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]
}

@test "the same message always produces the same id" {
	# Idempotence. A re-mine must overwrite its own artifact rather than add a
	# second, and every lesson citing that artifact must keep resolving.
	local a b
	a=$(archivist_mine_id "subject because reasons")
	b=$(archivist_mine_id "subject because reasons")
	[ "$a" = "$b" ]
}

# The id no longer takes a timestamp at all, so "stable across a re-mine at a
# different time" cannot be stated through this signature -- which is the
# point. It is asserted where a date really changes, in
# test/bats/archivist-mine-hook.bats. See ONL-169.

@test "a squash-appended pull request number does not change the id" {
	# GitHub appends " (#123)" to the subject when it squash-merges, so the
	# message read from the squash differs from the one read off the branch
	# commit by exactly that suffix. archivist_mine_normalize already strips the
	# squash bullet for this reason; the number has to go the same way or the
	# digest differs and content addressing buys nothing.
	local from_branch from_squash
	from_branch=$(archivist_mine_id "$(archivist_mine_normalize "subject line

body because reasons")")
	from_squash=$(archivist_mine_id "$(archivist_mine_normalize "subject line (#450)

body because reasons")")
	[ "$from_branch" = "$from_squash" ]
}

@test "different messages produce different ids" {
	local a b
	a=$(archivist_mine_id "first because reasons")
	b=$(archivist_mine_id "second because reasons")
	[ "$a" != "$b" ]
}

# There is deliberately no test that ids sort by the carrying commit's time.
# They did, and that is what broke idempotence above. The ordering bought
# nothing any reader uses: archivist_storage_load_ranked sorts by updated_at,
# librarian_archivist_load_since sorts by created_at, and nothing in either
# plugin sorts or ranges over the id. Both validators that touch an artifact id
# (librarian-archivist-reader.sh:42 and the evidence.artifact_ids rule in
# librarian-lesson-validate.sh:87) are charset-only regexes, and nothing
# decodes a ULID timestamp back out of one. See ONL-169.

@test "the id still passes the charset both validators require" {
	# 26 Crockford base32 chars. evidence.artifact_ids is validated against
	# this, so an id that stops matching silently invalidates every lesson that
	# cites it.
	run archivist_mine_id "subject because reasons"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]
}

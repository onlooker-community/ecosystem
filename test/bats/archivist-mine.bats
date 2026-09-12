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

@test "normalizing trims trailing whitespace" {
	local a b
	a=$(archivist_mine_normalize "subject because reasons")
	b=$(archivist_mine_normalize "subject because reasons

")
	[ "$a" = "$b" ]
}

@test "the id is a well-formed ULID" {
	run archivist_mine_id "subject because reasons" 1788618992794
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]]
}

@test "the same message and time always produce the same id" {
	# Idempotence. A re-mine must overwrite its own artifact rather than add a
	# second, and every lesson citing that artifact must keep resolving.
	local a b
	a=$(archivist_mine_id "subject because reasons" 1788618992794)
	b=$(archivist_mine_id "subject because reasons" 1788618992794)
	[ "$a" = "$b" ]
}

@test "different messages at the same instant produce different ids" {
	# Every message in one squashed pull request shares a carrying commit and
	# therefore a timestamp. Only the content half separates them.
	local a b
	a=$(archivist_mine_id "first because reasons" 1788618992794)
	b=$(archivist_mine_id "second because reasons" 1788618992794)
	[ "$a" != "$b" ]
}

@test "ids sort by the carrying commit's time" {
	# ULIDs sort lexicographically by their timestamp prefix, so a pull
	# request's artifacts sort at the moment it landed rather than in whatever
	# order the miner happened to visit them.
	local earlier later
	earlier=$(archivist_mine_id "same text" 1788618992794)
	later=$(archivist_mine_id "same text" 1788618999999)
	[[ "$earlier" < "$later" ]]
}

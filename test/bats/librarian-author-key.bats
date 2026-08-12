#!/usr/bin/env bats

# `run --separate-stderr` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	source "${PLUGIN_ROOT}/scripts/lib/librarian-author-key.sh"
}

@test "the secret lives outside any project directory" {
	# Every other librarian artifact is project-keyed. This one must not be:
	# a per-project secret would give one user a different identity in every
	# repo, silently.
	run librarian_author_secret_path
	[ "$status" -eq 0 ]
	[ "$output" = "${ONLOOKER_DIR}/author/user_secret" ]
	[[ "$output" != *"/librarian/"* ]] || return 1
}

@test "first use creates a secret with 0600 permissions" {
	run librarian_author_secret_ensure
	[ "$status" -eq 0 ]

	local path
	path=$(librarian_author_secret_path)
	[ -f "$path" ]
	# stat's portable-enough form for mode; %A on GNU, %Sp on BSD — use ls.
	local mode
	mode=$(ls -l "$path" | cut -c1-10)
	[ "$mode" = "-rw-------" ]
}

@test "the generated secret is 64 hex characters" {
	# openssl rand -hex 32 requests 32 BYTES and prints 64 characters.
	# Halving this to -hex 16 would halve the entropy and nothing would fail.
	run librarian_author_secret_ensure
	[ "$status" -eq 0 ]
	[ "${#output}" -eq 64 ]
	printf '%s' "$output" | grep -Eq '^[0-9a-f]{64}$' || return 1
}

@test "an existing secret is never regenerated" {
	# Load-bearing: regenerating silently changes the user's identity and
	# orphans every lesson they have written, including retraction.
	librarian_author_secret_ensure >/dev/null
	local path first second
	path=$(librarian_author_secret_path)
	first=$(cat "$path")

	librarian_author_secret_ensure >/dev/null
	second=$(cat "$path")
	[ "$first" = "$second" ]
}

@test "an empty secret is refused, not used" {
	# HMAC("", scope) is IDENTICAL for every user in this state — a corrupt
	# secret would silently collapse everyone onto one shared identity.
	#
	# --separate-stderr: bats' plain `run` merges stdout and stderr into
	# $output, but the interface contract is "empty stdout, reason on
	# stderr" — two distinct streams. Without separating them here, $output
	# could never be "" once the required stderr reason is written, no
	# matter how correct the implementation is.
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	: > "$path"

	run --separate-stderr librarian_author_secret_ensure
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
	# Pins the empty-secret guard specifically: an empty secret also trips
	# the short-secret check (0 < 64), so "refused" alone doesn't prove this
	# guard exists — the message must name the case, not just reject it.
	[[ "$stderr" == *"empty"* ]] || return 1
}

@test "a short secret is refused, naming the problem" {
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	printf 'abc123' > "$path"

	run librarian_author_secret_ensure
	[ "$status" -ne 0 ]
	[[ "$output" == *"too short"* ]] || return 1
}

@test "a world-readable secret is tightened and warned about" {
	local path
	path=$(librarian_author_secret_path)
	mkdir -p "$(dirname "$path")"
	openssl rand -hex 32 > "$path"
	chmod 0644 "$path"

	run librarian_author_secret_ensure
	[ "$status" -eq 0 ]
	[ "$(ls -l "$path" | cut -c1-10)" = "-rw-------" ]
	[[ "$output" == *"permissions"* ]] || return 1
}

@test "the lib never uses RANDOM for the secret" {
	# archivist-ulid.sh uses $RANDOM correctly for a sortable id; it is the
	# nearer example in this repo and the wrong one to copy for a secret.
	#
	# Comment lines are excluded: this pins usage, not mention. The lib's own
	# comment names $RANDOM directly to explain why it is disqualified, and a
	# grep that can't tell code from commentary would force that comment to
	# stop naming the thing it warns against.
	#
	# grep -c returns 0 with exit status 1 when there is no match — assert on
	# $output, not $status.
	run bash -c "grep -v '^[[:space:]]*#' \"${PLUGIN_ROOT}/scripts/lib/librarian-author-key.sh\" | grep -c 'RANDOM'"
	[ "$output" = "0" ]
}

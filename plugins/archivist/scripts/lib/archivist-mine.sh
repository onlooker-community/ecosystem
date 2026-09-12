#!/usr/bin/env bash
# Turn commit messages into artifact fields.
#
# Pure text: no git, no store, no hook payload. The split and the id are the
# two things most worth testing exhaustively, and keeping them free of I/O
# means their tests state the rules rather than build fixtures.
#
# Requires archivist-ulid.sh for _archivist_ulid_encode.

# Strip a leading "* " bullet and trailing blank lines.
#
# A squashed pull request carries each authored message behind a bullet; a
# single-commit one carries its body verbatim. Normalizing makes both spell the
# same message, which is what lets an id survive a squash - and surviving a
# squash is the whole reason the id is derived from content rather than from a
# commit SHA, which this workflow rewrites by design.
archivist_mine_normalize() {
	local message="$1"
	message="${message#\* }"
	# Command substitution already eats trailing newlines; this also drops
	# trailing spaces on the last line so two spellings of the same message
	# cannot hash differently.
	printf '%s' "$(printf '%s' "$message" | sed 's/[[:space:]]*$//')"
}

# Split a squashed body into its authored messages, NUL-separated.
#
# NUL rather than newline because every message contains newlines, so a
# line-oriented separator cannot express this.
archivist_mine_split() {
	local body="$1"

	# No bullets means one authored message, carried verbatim.
	if ! printf '%s\n' "$body" | grep -q '^\* '; then
		archivist_mine_normalize "$body"
		return 0
	fi

	local current="" first=1 line
	while IFS= read -r line; do
		if [[ "$line" == '* '* ]]; then
			if [[ $first -eq 0 ]]; then
				archivist_mine_normalize "$current"
				printf '\0'
			fi
			first=0
			current="$line"
		else
			current="${current}"$'\n'"${line}"
		fi
	done <<< "$body"

	[[ $first -eq 0 ]] && archivist_mine_normalize "$current"
	return 0
}

# A ULID derived from the message, carried at the given instant.
#
# The randomness half is SHA256 over the normalized message, so the id survives
# a squash, a rebase and a cherry-pick - every one of which rewrites the SHA
# this could otherwise have used. It has to be stable: evidence.artifact_ids in
# the lesson contract cites these, so a re-mine that minted fresh ids would
# leave every lesson pointing at an artifact that no longer exists, silently.
#
# The timestamp half is the carrying commit's date, so a pull request's
# artifacts sort together at the moment it landed.
#
# Usage: archivist_mine_id <normalized_message> <epoch_ms>
archivist_mine_id() {
	local message="$1"
	local epoch_ms="$2"

	local digest
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$message" | shasum -a 256 | cut -c1-20)
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$message" | sha256sum | cut -c1-20)
	else
		return 1
	fi

	# Eighty bits as two forty-bit halves, matching how archivist_ulid builds
	# its own randomness so both pass through the same encoder.
	local hi=$((16#${digest:0:10}))
	local lo=$((16#${digest:10:10}))

	printf '%s%s%s' \
		"$(_archivist_ulid_encode "$epoch_ms" 10)" \
		"$(_archivist_ulid_encode "$hi" 8)" \
		"$(_archivist_ulid_encode "$lo" 8)"
}

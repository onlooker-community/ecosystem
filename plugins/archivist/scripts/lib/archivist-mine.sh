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
	# Two spellings of the same message must not hash differently, so both
	# things a merge does to a subject are undone here.
	#
	# `1s` -- the pull request number GitHub appends when it squash-merges, and
	# ONLY on the subject line. A number in the body is content: "reverts the
	# change from (#450)" and "... (#451)" are different messages and must stay
	# different ids. Without this the squash's digest differed from the branch
	# commit's and content addressing bought nothing, which is half of ONL-169.
	#
	# The second expression is the original trailing-whitespace trim. Command
	# substitution already eats trailing newlines; sed drops trailing spaces on
	# every line.
	printf '%s' "$(printf '%s' "$message" \
		| sed -e '1s/[[:space:]]\{1,\}(#[0-9]\{1,\})[[:space:]]*$//' -e 's/[[:space:]]*$//')"
}

# Well-known git trailer keys, for the rationale test below. Deliberately a
# CLOSED list rather than a `^Word:` pattern: that pattern also strips prose
# like "Problem: events were dropped." or "Note: this matters", which is the
# reasoning the pipeline exists to capture. Measured against this repo's store,
# the closed list catches 166 records and the greedy pattern 173 -- the extra 7
# are prose, and keeping a noise record costs a model call while dropping a real
# decision costs the lesson.
_ARCHIVIST_MINE_TRAILER_KEYS='co-authored-by|signed-off-by|reviewed-by|acked-by|tested-by|reported-by|suggested-by|cc|change-id|claude-session|breaking-change'

# Does this body carry a rationale, or only metadata? (ONL-170)
#
# The existing rule one layer up is "a subject with no body is a claim with no
# rationale". This is the same judgment for a body that is PRESENT but says
# nothing: a release-please commit's changelog bullets are consumed by the
# squash split, and the body that survives is a lone `Co-authored-by:` trailer.
# 84 of those became decision artifacts in this repo's store, along with 67
# identical auto-format commits -- 16% of the corpus, each one paid for twice
# downstream by the classifier and again by the lesson transform.
#
# Separator rules go too, because the formatter's commits are a `---------`
# line and a trailer and nothing else.
#
# Returns 0 when prose remains, 1 when nothing does.
#
# Usage: archivist_mine_has_rationale <detail>
archivist_mine_has_rationale() {
	local detail="$1"
	[[ -z "$detail" ]] && return 1

	local left
	left=$(printf '%s' "$detail" \
		| sed -E '/^[[:space:]]*$/d; /^[[:space:]]*-{3,}[[:space:]]*$/d' \
		| grep -viE "^(${_ARCHIVIST_MINE_TRAILER_KEYS}):[[:space:]]" \
		| tr -d '[:space:]')

	[[ -n "$left" ]]
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
# NO TIMESTAMP, and that is the whole point (ONL-169). This used to prefix the
# carrying commit's date so a pull request's artifacts would sort together --
# and that defeated the stability the paragraph above promises, in exactly the
# squash/rebase/cherry-pick case it names. Every one of those rewrites the
# commit date, so the message was identical, the date was not, and the re-mine
# appended a second artifact instead of overwriting the first. 192 of 1011
# mined artifacts in this repo's own store (18%) were duplicate content.
#
# The ordering it bought was read by nobody: archivist_storage_load_ranked
# sorts by updated_at, librarian_archivist_load_since sorts by created_at, and
# nothing in either plugin sorts or ranges over an artifact id. The carrying
# date is still recorded -- as created_at on the artifact, which is the field
# those readers actually use.
#
# Still 26 Crockford base32 chars, because that charset IS load-bearing:
# librarian-archivist-reader.sh:42 and the evidence.artifact_ids rule in
# librarian-lesson-validate.sh:87 both validate against it, and nothing
# anywhere decodes a ULID timestamp back out of one.
#
# Usage: archivist_mine_id <normalized_message>
archivist_mine_id() {
	local message="$1"

	# Thirty hex chars = 120 bits, which is what three encoder calls consume.
	local digest
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$message" | shasum -a 256 | cut -c1-30)
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$message" | sha256sum | cut -c1-30)
	else
		return 1
	fi

	# Three forty-bit thirds, matching how archivist_ulid builds its own
	# randomness so both pass through the same encoder.
	local a=$((16#${digest:0:10}))
	local b=$((16#${digest:10:10}))
	local c=$((16#${digest:20:10}))

	printf '%s%s%s' \
		"$(_archivist_ulid_encode "$a" 10)" \
		"$(_archivist_ulid_encode "$b" 8)" \
		"$(_archivist_ulid_encode "$c" 8)"
}

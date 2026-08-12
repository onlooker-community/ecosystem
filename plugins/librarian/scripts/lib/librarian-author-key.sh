#!/usr/bin/env bash
# Author identity for lesson promotion.
#
# author_key is derived PER VISIBILITY SCOPE so a user's org identity and their
# public identity cannot be linked by anyone who does not hold their secret.
#
# Breaking that unlinkability breaks it SILENTLY: nothing throws, and the pool
# fills with well-formed keys that leak the association they exist to prevent.
# The golden-vector test in test/bats/librarian-author-key.bats is what makes
# any change to this derivation go red.
#
# Exposes:
#   librarian_author_secret_path
#   librarian_author_secret_ensure
#   librarian_author_key <visibility>

# Where the secret lives.
#
# NOT project-keyed, deliberately. Every other librarian artifact sits under
# librarian_project_dir; this one must not, because one user is one author
# across all their repos. A per-project secret would hand the same person a
# different identity in every project, and nothing would report it.
librarian_author_secret_path() {
	printf '%s/author/user_secret' "${ONLOOKER_DIR:-$HOME/.onlooker}"
}

# Echo a valid secret, creating one on first use.
#
# Returns non-zero with empty stdout if it cannot produce a valid secret. An
# invalid secret is never "repaired" by regenerating: an existing file is
# authoritative, because replacing it silently changes the user's identity.
librarian_author_secret_ensure() {
	local path dir
	path="$(librarian_author_secret_path)"
	dir="$(dirname "$path")"

	if [[ ! -f "$path" ]]; then
		command -v openssl >/dev/null 2>&1 || {
			printf 'author-key: openssl is required to create a secret.\n' >&2
			return 1
		}
		mkdir -p "$dir" 2>/dev/null || {
			printf 'author-key: cannot create %s\n' "$dir" >&2
			return 1
		}
		# 32 BYTES, printed as 64 hex characters. Do not substitute the
		# shell's built-in pseudo-random-number variable used elsewhere in
		# this repo for ULIDs — it carries only 15 bits of entropy, fine for
		# a sortable id and disqualifying for a secret.
		local generated
		generated=$(openssl rand -hex 32 2>/dev/null) || {
			printf 'author-key: openssl rand failed.\n' >&2
			return 1
		}
		# Create restricted, then write — never write then chmod, which leaves
		# a window where the secret is world-readable on disk.
		( umask 077 && printf '%s\n' "$generated" > "$path" ) || {
			printf 'author-key: cannot write %s\n' "$path" >&2
			return 1
		}
	fi

	# Tighten loose permissions and say so. Refusing would block promotion over
	# something the user cannot fix without guidance; staying silent would hide
	# a real exposure. Tightening does not undo an exposure that already
	# happened — it stops the next one, and the warning is the part that counts.
	local mode
	mode=$(ls -l "$path" 2>/dev/null | cut -c1-10)
	if [[ "$mode" != "-rw-------" ]]; then
		chmod 0600 "$path" 2>/dev/null
		printf 'author-key: tightened permissions on %s (was %s)\n' "$path" "$mode" >&2
	fi

	local secret
	secret=$(cat "$path" 2>/dev/null | tr -d '\n')
	if [[ -z "$secret" ]]; then
		printf 'author-key: secret at %s is empty; refusing to derive.\n' "$path" >&2
		return 1
	fi
	# A short-but-nonempty secret still derives a plausible key with less
	# entropy than this design claims. 64 is the width openssl rand -hex 32
	# produces.
	if [[ "${#secret}" -lt 64 ]]; then
		printf 'author-key: secret at %s is too short (%d chars, expected 64).\n' \
			"$path" "${#secret}" >&2
		return 1
	fi

	printf '%s' "$secret"
}

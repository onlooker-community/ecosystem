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

	# Set only when THIS call is the one whose content actually landed at
	# $path (won any creation race, below). Read by the tighten step further
	# down: a file we just created under umask 077 is already 0600, and
	# tightening it unconditionally would silently repair a regression in
	# the creation path itself before anything could observe it.
	local created=0

	if [[ ! -f "$path" ]]; then
		command -v openssl >/dev/null 2>&1 || {
			printf 'author-key: openssl is required to create a secret.\n' >&2
			return 1
		}
		mkdir -p "$dir" 2>/dev/null || {
			printf 'author-key: cannot create %s\n' "$dir" >&2
			return 1
		}
		# 32 BYTES, printed as 64 hex characters. Not $RANDOM: that is a
		# 15-bit PRNG, correct for archivist's sortable ULIDs and wrong for
		# a secret.
		local generated
		generated=$(openssl rand -hex 32 2>/dev/null) || {
			printf 'author-key: openssl rand failed.\n' >&2
			return 1
		}

		# Atomic create-if-absent: write to a private temp file in the same
		# directory, then hard-link it into place. `ln` fails if the target
		# already exists — the portable atomic-create idiom. Two concurrent
		# first-use callers race here; only one wins, the loser's own
		# generated value is discarded, and every caller (winner and
		# losers alike) reads back whatever actually landed on disk below.
		# Without this, two concurrent first-use calls can each write
		# $path directly and hand two different callers two different
		# secrets — two identities for one user.
		local tmp
		tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || {
			printf 'author-key: cannot create a temp file in %s\n' "$dir" >&2
			return 1
		}
		# Belt-and-suspenders with mktemp's own restrictive creation mode —
		# create restricted, then write, never write-then-chmod, which
		# would leave a window where the secret is world-readable on disk.
		( umask 077 && printf '%s\n' "$generated" > "$tmp" ) || {
			printf 'author-key: cannot write %s\n' "$tmp" >&2
			rm -f "$tmp" 2>/dev/null
			return 1
		}
		if ln "$tmp" "$path" 2>/dev/null; then
			created=1
		fi
		# Someone else winning the race is not an error — clean up our
		# losing copy either way.
		rm -f "$tmp" 2>/dev/null
	fi

	# Tighten loose permissions and say so, but only on a file that already
	# existed before this call: a file THIS call just created above was
	# written under umask 077 and is already 0600. Running this
	# unconditionally on every call — including the one that just created
	# the file — would silently repair a weakened creation path before any
	# caller, or test, could observe the exposure.
	if [[ "$created" -eq 0 ]]; then
		# Refusing here would block promotion over something the user cannot
		# fix without guidance; staying silent would hide a real exposure.
		# Tightening does not undo an exposure that already happened — it
		# stops the next one, and the warning is the part that counts.
		local mode
		mode=$(ls -l "$path" 2>/dev/null | cut -c1-10)
		if [[ "$mode" != "-rw-------" ]]; then
			chmod 0600 "$path" 2>/dev/null
			printf 'author-key: tightened permissions on %s (was %s)\n' "$path" "$mode" >&2
		fi
	fi

	# The classic mode string is blind to ACLs: `chmod +a "everyone allow
	# read"` on a 0600 file yields "-rw-------+" on macOS — the extra grant
	# sits at column 11, outside the window the mode check above reads, and
	# chmod cannot clear it. An inherited ACL from MDM policy or a
	# network-mounted home is a plausible non-malicious way to hit this, not
	# just a deliberate change. Warn explicitly rather than claim a fix we
	# cannot make; do not attempt to strip ACLs portably.
	local acl_flag
	acl_flag=$(ls -l "$path" 2>/dev/null | cut -c11)
	if [[ "$acl_flag" == "+" ]]; then
		printf 'author-key: %s carries an ACL granting access beyond its file mode (mode alone will not show this); chmod cannot clear it — review and remove it manually.\n' "$path" >&2
	fi

	local secret
	secret=$(cat "$path" 2>/dev/null | tr -d '\n')
	if [[ -z "$secret" ]]; then
		printf 'author-key: secret at %s is empty; refusing to derive.\n' "$path" >&2
		return 1
	fi
	# A short-but-nonempty secret still derives a plausible key with less
	# entropy than this design claims. 64 is the floor width openssl
	# rand -hex 32 produces — longer is accepted; HMAC does not care about
	# extra key width.
	if [[ "${#secret}" -lt 64 ]]; then
		printf 'author-key: secret at %s is too short (%d chars, expected 64).\n' \
			"$path" "${#secret}" >&2
		return 1
	fi
	# Length is not content: 64 characters of the wrong shape (spaces,
	# uppercase, punctuation) passes the check above and would still derive
	# a garbage-but-deterministic identity from HMAC — accepted-but-wrong is
	# worse than rejected outright, because nothing downstream can tell the
	# difference between that and a real one.
	if ! printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64,}$'; then
		printf 'author-key: secret at %s is malformed (expected 64+ lowercase hex characters).\n' \
			"$path" >&2
		return 1
	fi

	printf '%s' "$secret"
}

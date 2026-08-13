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
		# Captured now, while it is still known: if $path turns out to be
		# a directory below, the stray secret `ln` leaves behind is named
		# after this.
		local tmp_basename
		tmp_basename="$(basename "$tmp")"
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

		# `ln FILE DIR` succeeds — POSIX `ln` links basename(FILE) *inside*
		# an existing directory rather than failing — so a directory
		# sitting at $path makes the `ln` above "succeed" (created=1)
		# while $path itself is still that directory, not a secret. Left
		# alone, the stray hard link at $path/$tmp_basename is live secret
		# material nothing ever reads again. Catch it here, while the name
		# is still known, and remove it before refusing.
		if [[ "$created" -eq 1 && ! -f "$path" ]]; then
			rm -f "${path}/${tmp_basename}" 2>/dev/null
			printf 'author-key: %s is not a regular file; refusing to create a secret there.\n' "$path" >&2
			return 1
		fi
	fi

	# A pre-existing non-regular file at $path (a FIFO, a socket, a device
	# node) also fails the `-f` check above and enters the block above —
	# but `ln` refuses to link onto an existing non-directory path, so
	# `created` stays 0 and the directory case just above never fires.
	# Catch it here instead: before the tighten step below touches its
	# mode, and before the plain `cat` further down would block forever
	# reading a FIFO with no writer. Plugins must never hang a session.
	if [[ ! -f "$path" ]]; then
		printf 'author-key: %s is not a regular file; refusing to read a secret from it.\n' "$path" >&2
		return 1
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

	# Read only the FIRST LINE, and validate it before any other processing.
	# `head -n1` never touches bytes past the first newline, which matters
	# for two reasons at once: a secret file is never regenerated (see
	# above), so the documented way to move it to a second machine is a
	# plain copy — but a user who instead appends (`>>` instead of `>`, or
	# restoring a backup on top of an existing file) leaves a *second*
	# 64-hex line sitting after the first. Stripping newlines from the
	# whole file before validating would concatenate the two lines into a
	# 128-character string that reads as one long-but-"valid" secret — a
	# THIRD identity, matching neither machine, accepted silently. Reading
	# only line one sidesteps that: whatever is on later lines is simply
	# never read.
	local secret
	secret=$(head -n1 "$path" 2>/dev/null)
	if [[ -z "$secret" ]]; then
		printf 'author-key: secret at %s is empty; refusing to derive.\n' "$path" >&2
		return 1
	fi
	# A short-but-nonempty secret still derives a plausible key with less
	# entropy than this design claims. 64 is the exact width openssl
	# rand -hex 32 produces.
	if [[ "${#secret}" -lt 64 ]]; then
		printf 'author-key: secret at %s is too short (%d chars, expected 64).\n' \
			"$path" "${#secret}" >&2
		return 1
	fi
	# Anchored and EXACT, not "64 or more": a longer key is not a wider
	# version of the same secret, it is a DIFFERENT secret — HMAC does not
	# ignore the extra width, it derives a different identity from it.
	# Accepting anything past 64 chars here is exactly how a stray longer
	# first line (or the wrong-shape content below) becomes a silently
	# wrong-but-well-formed author_key rather than a refusal.
	#
	# This is also what catches wrong-shape content: 64 characters of the
	# wrong shape (spaces, uppercase, punctuation) passes the length check
	# above and would still derive a garbage-but-deterministic identity
	# from HMAC — accepted-but-wrong is worse than rejected outright,
	# because nothing downstream can tell the difference between that and
	# a real one.
	if ! printf '%s' "$secret" | grep -Eq '^[0-9a-f]{64}$'; then
		printf 'author-key: secret at %s is malformed (expected exactly 64 lowercase hex characters).\n' \
			"$path" >&2
		return 1
	fi

	printf '%s' "$secret"
}

# Derive this user's author_key for one visibility scope.
#
#   HMAC-SHA256(secret, "onlooker.author.v1:<visibility>")
#   truncated to 16 bytes, rendered as 32 lowercase hex
#
# The domain tag stops this secret's output colliding with any other use of the
# same secret. The version is what lets a future v2 add an org identity without
# silently rederiving every existing key: v1 lessons keep validating under v1.
#
# No org id in v1 — none exists in this system, and inventing one for an
# unwritten consumer is the mistake ecosystem-si6 avoided.
#
# Usage: librarian_author_key <private|org|public>
librarian_author_key() {
	local visibility="${1:-}"
	case "$visibility" in
		private|org|public) ;;
		*)
			printf 'author-key: unrecognized visibility: %s\n' "$visibility" >&2
			return 1
			;;
	esac

	# node, not openssl: openssl's `dgst -hmac` CLI has no way to take the
	# HMAC key off argv. On Linux /proc/<pid>/cmdline is world-readable, so
	# any local user could read the secret out of the process table for
	# the life of the call. node reads it from the environment instead
	# (AK_SECRET, below) — /proc/<pid>/environ is owner-only. Visibility is
	# not secret and stays on argv. The algorithm is unchanged: verified
	# against the golden vectors byte-for-byte before this switch.
	command -v node >/dev/null 2>&1 || {
		printf 'author-key: node is required to derive a key.\n' >&2
		return 1
	}

	local secret
	secret=$(librarian_author_secret_ensure) || return 1

	local digest
	digest=$(AK_SECRET="$secret" node -e '
const crypto = require("crypto");
process.stdout.write(
	crypto.createHmac("sha256", process.env.AK_SECRET)
		.update("onlooker.author.v1:" + process.argv[1])
		.digest("hex")
);
' "$visibility" 2>/dev/null) || {
		printf 'author-key: HMAC failed.\n' >&2
		return 1
	}

	# 64 hex chars in, 32 out. Truncating an HMAC is standard; 128 bits is
	# ample for a collision-resistant pseudonymous identifier. Anchored and
	# on the CHARSET, not just the width: a width-only check lets 64 bytes
	# of anything through a misbehaving node subprocess, and the truncated
	# result would still violate this function's own 32-lowercase-hex
	# contract — this is what actually provides fail-closed behavior if the
	# subprocess misbehaves, since the command substitution above has no
	# `pipefail` to catch a partial write on its own.
	if ! printf '%s' "$digest" | grep -Eq '^[0-9a-f]{64}$'; then
		printf 'author-key: HMAC returned a malformed digest (expected 64 lowercase hex characters).\n' >&2
		return 1
	fi
	printf '%s' "${digest:0:32}"
}

#!/usr/bin/env bats

# ONL-164. A project key is derived in exactly one place: the vendored
# onlooker-project-key.sh. shared-lib-vendoring.bats keeps every copy of that
# lib byte-identical, but it finds them by filename (*-project-key.sh), so a
# derivation written anywhere else is invisible to it. memory-recall-tracker
# hand-rolled one in a hook body for exactly that reason, and it was the one
# event that carried two independently derived keys — the payload's and the
# envelope's.
#
# So this guard keys on what a derivation DOES rather than where it lives: it
# hashes a "remote:"- or "root:"-prefixed value. Nothing else in the tree builds
# that string, so it finds a new derivation in a hook, a lib, a lint script or
# a JS module, under any filename.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
}

# A quote or backtick, then remote: or root:, then a variable. `^[^#]*` keeps a
# shell comment that describes the scheme from counting as a derivation.
SHAPE='^[^#]*["`](remote|root):\$'

# Known derivations outside the canonical lib, each with the issue that removes
# it. An entry here is a debt, not a permission: the second test fails the day
# its file stops matching, so the fix has to delete the entry too. Empty since
# ONL-152 moved check-plugin-liveness.mjs onto the lib. Expanded with the
# `${a[@]+...}` form below because bash 3.2 calls an empty array unbound.
KNOWN_EXCEPTIONS=()

# Every tracked file under scripts/ and plugins/ whose code builds a
# remote:/root: key input from a variable. Matches the shell forms
# "remote:${x}" / "remote:$x" and the JS template literal `remote:${x}`.
# Comments are skipped so prose describing the scheme does not count.
_derivation_sites() {
	cd "$REPO_ROOT" || return 1
	git ls-files -z -- 'scripts/*' 'plugins/*' \
		| xargs -0 grep -lE "$SHAPE" 2>/dev/null \
		| grep -vE '(^|/)onlooker-project-key\.sh$' \
		| grep -vE '\.(md|json)$' \
		| sort
}

@test "no file outside the canonical lib derives a project key" {
	local sites unexpected="" site known k
	sites=$(_derivation_sites)
	while IFS= read -r site; do
		[[ -z "$site" ]] && continue
		known=0
		for k in ${KNOWN_EXCEPTIONS[@]+"${KNOWN_EXCEPTIONS[@]}"}; do
			[[ "$site" == "$k" ]] && known=1
		done
		[[ "$known" -eq 0 ]] && unexpected+="${site}"$'\n'
	done <<<"$sites"

	if [[ -n "$unexpected" ]]; then
		printf 'derives a project key outside onlooker-project-key.sh:\n%s' "$unexpected" >&2
		printf 'source the canonical lib and call onlooker_project_resolve_cached instead\n' >&2
		return 1
	fi
}

@test "every known exception still derives a key, so a fixed one is removed from the list" {
	local sites k stale=""
	sites=$(_derivation_sites)
	for k in ${KNOWN_EXCEPTIONS[@]+"${KNOWN_EXCEPTIONS[@]}"}; do
		grep -qxF "$k" <<<"$sites" || stale+="${k}"$'\n'
	done
	if [[ -n "$stale" ]]; then
		printf 'no longer derives a key; drop it from KNOWN_EXCEPTIONS:\n%s' "$stale" >&2
		return 1
	fi
}

# The guard is only worth having if its pattern actually bites. Plant each form
# it claims to catch in a scratch copy and check the matcher sees it.
@test "the shape matcher catches the shell and JS derivation forms" {
	local f="${BATS_TEST_TMPDIR}/probe"
	local form
	for form in \
		'k=$(_h "remote:${REMOTE}")' \
		'k=$(_h "root:$ROOT")' \
		'return first12(`remote:${remote}`);'; do
		printf '%s\n' "$form" >"$f"
		grep -qE "$SHAPE" "$f" || {
			printf 'matcher missed: %s\n' "$form" >&2
			return 1
		}
	done
	# Prose in a comment is not a derivation.
	printf '%s\n' '# Mirrors sha256("remote:${url}") from the lib' >"$f"
	! grep -qE "$SHAPE" "$f"
}

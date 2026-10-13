#!/usr/bin/env bats
# Substrate project-key derivation (ecosystem-449.59).

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name "Test"
}

@test "derives a 12-char hex key from the origin remote" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	key=$(onlooker_project_key "$REPO")
	[[ "$key" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "the remote key is stable across two clones at different paths" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	local other="${BATS_TEST_TMPDIR}/elsewhere"
	mkdir -p "$other"
	git -C "$other" init -q
	git -C "$other" remote add origin git@github.com:org/fixture.git

	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$other")" ]
}

@test "different remotes yield different keys" {
	git -C "$REPO" remote add origin git@github.com:org/one.git
	local other="${BATS_TEST_TMPDIR}/two"
	mkdir -p "$other"
	git -C "$other" init -q
	git -C "$other" remote add origin git@github.com:org/two.git

	[ "$(onlooker_project_key "$REPO")" != "$(onlooker_project_key "$other")" ]
}

@test "falls back to the repo root when there is no remote" {
	key=$(onlooker_project_key "$REPO")
	[[ "$key" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "the remote key and the rootless key differ for the same repo" {
	local rootless; rootless=$(onlooker_project_key "$REPO")
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	[ "$rootless" != "$(onlooker_project_key "$REPO")" ]
}

@test "a worktree shares its parent's key" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	git -C "$REPO" commit -q --allow-empty -m "base"
	local wt="${BATS_TEST_TMPDIR}/wt"
	git -C "$REPO" worktree add -q -b wt-branch "$wt" >/dev/null 2>&1

	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$wt")" ]
}

@test "a worktree of a remoteless repo still shares its parent's key" {
	# The common-dir path, not the remote path. This is the branch
	# ecosystem-449.37 is about: resolve to the parent checkout for identity.
	git -C "$REPO" commit -q --allow-empty -m "base"
	local wt="${BATS_TEST_TMPDIR}/wt2"
	git -C "$REPO" worktree add -q -b wt2-branch "$wt" >/dev/null 2>&1

	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$wt")" ]
}

@test "returns empty outside a git repo" {
	local plain="${BATS_TEST_TMPDIR}/plain"
	mkdir -p "$plain"
	[ -z "$(onlooker_project_key "$plain")" ]
}

@test "worktree_root resolves a linked worktree to ITSELF, not its parent" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	git -C "$REPO" commit -q --allow-empty -m "base"
	local wt="${BATS_TEST_TMPDIR}/wt-self"
	git -C "$REPO" worktree add -q -b wt-self-branch "$wt" >/dev/null 2>&1

	# Identity collapses the two; location must not.
	[ "$(onlooker_project_key "$REPO")" = "$(onlooker_project_key "$wt")" ]
	[ "$(onlooker_worktree_root "$wt")" != "$(onlooker_worktree_root "$REPO")" ]
	[ "$(onlooker_worktree_root "$wt")" = "$(cd "$wt" && pwd -P)" ]
}

@test "worktree_root returns the toplevel for an ordinary checkout" {
	[ "$(onlooker_worktree_root "$REPO")" = "$(cd "$REPO" && pwd -P)" ]
}

@test "worktree_root returns empty outside a git repo" {
	local plain="${BATS_TEST_TMPDIR}/plain-wt"
	mkdir -p "$plain"
	[ -z "$(onlooker_worktree_root "$plain")" ]
}

@test "worktree_root returns empty for an absent or non-directory argument" {
	[ -z "$(onlooker_worktree_root "")" ]
	[ -z "$(onlooker_worktree_root "${BATS_TEST_TMPDIR}/does-not-exist")" ]
}

@test "resolve exports basis=remote for a repo with an origin" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_BASIS" = "remote" ]
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "resolve exports basis=root for a repo with no origin" {
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_BASIS" = "root" ]
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1
}

@test "resolve exports both empty outside a git repo" {
	local plain="${BATS_TEST_TMPDIR}/plain-resolve"
	mkdir -p "$plain"
	onlooker_project_resolve "$plain"
	[ -z "$ONLOOKER_PROJECT_KEY" ]
	[ -z "$ONLOOKER_PROJECT_BASIS" ]
}

@test "resolve clears a stale value rather than leaving the previous one" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ -n "$ONLOOKER_PROJECT_KEY" ]

	local plain="${BATS_TEST_TMPDIR}/plain-clear"
	mkdir -p "$plain"
	onlooker_project_resolve "$plain"
	[ -z "$ONLOOKER_PROJECT_KEY" ]
	[ -z "$ONLOOKER_PROJECT_BASIS" ]
}

@test "resolve exports the variables to a child process" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	run env
	[ "$status" -eq 0 ]
	echo "$output" | grep -q "^ONLOOKER_PROJECT_BASIS=remote$"
}

@test "the key from resolve matches the key from the wrapper" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	onlooker_project_resolve "$REPO"
	[ "$ONLOOKER_PROJECT_KEY" = "$(onlooker_project_key "$REPO")" ]
}

@test "the export survives a direct call but not command substitution" {
	git -C "$REPO" remote add origin git@github.com:org/fixture.git

	# Direct call, in the current shell: the export is visible afterward.
	unset ONLOOKER_PROJECT_KEY ONLOOKER_PROJECT_BASIS
	onlooker_project_key "$REPO" >/dev/null
	[ "$ONLOOKER_PROJECT_BASIS" = "remote" ] || return 1
	[[ "$ONLOOKER_PROJECT_KEY" =~ ^[0-9a-f]{12}$ ]] || return 1

	# Command substitution — the form every production call site uses — runs
	# the call in a subshell, so the export dies there and never reaches this
	# shell. This is the form that reaches zero callers' env.
	unset ONLOOKER_PROJECT_KEY ONLOOKER_PROJECT_BASIS
	local captured
	captured=$(onlooker_project_key "$REPO")
	[ -n "$captured" ] || return 1
	[ -z "${ONLOOKER_PROJECT_BASIS:-}" ] || return 1
	[ -z "${ONLOOKER_PROJECT_KEY:-}" ] || return 1
}

@test "key is stable across calls" {
	git -C "$REPO" remote add origin https://example.com/foo/bar.git
	a=$(onlooker_project_key "$REPO")
	b=$(onlooker_project_key "$REPO")
	[ "$a" = "$b" ]
}

@test "the root-derived key is stable across calls for a remote-less repo" {
	a=$(onlooker_project_key "$REPO")
	b=$(onlooker_project_key "$REPO")
	[ "$a" = "$b" ]
}

@test "onlooker_project_remote_url prints origin url when set" {
	local d="${BATS_TEST_TMPDIR}/remote-set"
	mkdir -p "$d"
	git -C "$d" init -q
	git -C "$d" remote add origin https://example.com/x.git

	run onlooker_project_remote_url "$d"
	[ "$status" -eq 0 ]
	[ "$output" = "https://example.com/x.git" ]
}

@test "onlooker_project_remote_url returns empty when repo has no remote" {
	local d="${BATS_TEST_TMPDIR}/remote-none"
	mkdir -p "$d"
	git -C "$d" init -q

	run onlooker_project_remote_url "$d"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "onlooker_project_remote_url returns empty for a non-git directory" {
	local d="${BATS_TEST_TMPDIR}/remote-non-git"
	mkdir -p "$d"

	run onlooker_project_remote_url "$d"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "onlooker_project_remote_url returns empty for a nonexistent path" {
	run onlooker_project_remote_url "${BATS_TEST_TMPDIR}/does-not-exist"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "onlooker_project_repo_root prints the repo toplevel realpath" {
	local d="${BATS_TEST_TMPDIR}/root-repo"
	mkdir -p "$d"
	git -C "$d" init -q

	# Physical path: matches the function's pwd -P resolution on platforms
	# (e.g. macOS) where the temp dir is reached through a symlink.
	local expected
	expected="$(cd "$d" && pwd -P)"

	run onlooker_project_repo_root "$d"
	[ "$status" -eq 0 ]
	[ "$output" = "$expected" ]
}

@test "onlooker_project_repo_root resolves toplevel from a subdirectory" {
	local d="${BATS_TEST_TMPDIR}/root-repo-sub"
	mkdir -p "$d/nested/deep"
	git -C "$d" init -q

	local expected
	expected="$(cd "$d" && pwd -P)"

	run onlooker_project_repo_root "$d/nested/deep"
	[ "$status" -eq 0 ]
	[ "$output" = "$expected" ]
}

@test "onlooker_project_repo_root returns empty for a non-git directory" {
	local d="${BATS_TEST_TMPDIR}/root-non-git"
	mkdir -p "$d"

	run onlooker_project_repo_root "$d"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "onlooker_project_repo_root returns empty for a nonexistent path" {
	run onlooker_project_repo_root "${BATS_TEST_TMPDIR}/root-missing"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# Hash-tier preference (ONL-150).
#
# The tiers are ordered by MEASURED cost, so the order is a behavior worth
# pinning rather than an implementation detail. Measured on an M-series mac,
# 200 calls each, through the exact production pipeline:
#
#   sha256sum   2.10 ms     openssl   2.34 ms
#   shasum     14.51 ms     python3  21.70 ms
#
# shasum is a Perl script, which is the whole story - and it was first, so
# every derivation on every platform took the 14.51 ms path. lineage derives a
# key on EVERY PostToolUse (lineage-post-tool-use.sh:244 and :302), and this
# repo treats per-edit hook latency as a budget.
#
# Availability decides the order among the fast two, not the 0.24 ms between
# them: sha256sum is coreutils and absent from a stock macOS, while openssl is
# /usr/bin/openssl and ships with it. So sha256sum first wins on Linux and CI,
# openssl catches a stock Mac, and shasum stays last as the tier macOS can
# always reach.

# A PATH containing ONLY the named hash stubs, plus the real `cut` and `sed`
# the pipelines need. Each stub prints a distinguishable digest, so the key the
# function returns names the tier it chose.
_stub_path() {
	local dir="${BATS_TEST_TMPDIR}/hashstubs"
	rm -rf "$dir"
	mkdir -p "$dir"
	ln -s "$(command -v cut)" "${dir}/cut"
	ln -s "$(command -v sed)" "${dir}/sed"

	# `#!/bin/sh`, NOT `#!/usr/bin/env bash`: PATH here holds only this stub
	# directory, and `env bash` resolves `bash` through PATH - so an env-shebang
	# stub is simply not executable under the very condition these tests create,
	# and the function then reports the NEXT tier as if the stub tier were
	# missing. That reads exactly like an ordering bug in the code under test.
	local tool
	for tool in "$@"; do
		case "$tool" in
			sha256sum) printf '#!/bin/sh\nprintf "%%s  -\\n" "aaaaaaaaaaaaaaaa"\n' >"${dir}/sha256sum" ;;
			# Bare hex, which is what LibreSSL on macOS actually prints - the
			# `SHA2-256(stdin)= ` prefix the sed strips is another build's
			# format, so the sed must be a no-op here and is.
			openssl)   printf '#!/bin/sh\nprintf "%%s\\n" "bbbbbbbbbbbbbbbb"\n' >"${dir}/openssl" ;;
			shasum)    printf '#!/bin/sh\nprintf "%%s  -\\n" "cccccccccccccccc"\n' >"${dir}/shasum" ;;
		esac
		chmod +x "${dir}/${tool}"
	done
	printf '%s' "$dir"
}

# Derive with ONLY the named tiers reachable.
#
# The PATH override is scoped to a subshell rather than assigned in the test
# body: the stub directory holds no `rm`, and bats' own per-test teardown runs
# in the test's shell, so clobbering PATH there breaks the harness itself
# ("rm: command not found") and the failure looks like the code under test.
_derive_with_tiers() {
	local dir
	dir=$(_stub_path "$@")
	( PATH="$dir"; _onlooker_sha256_first12 "remote:x" )
}

@test "prefers sha256sum when every tier is available" {
	[ "$(_derive_with_tiers sha256sum openssl shasum)" = "aaaaaaaaaaaa" ]
}

@test "falls to openssl when sha256sum is absent, not to shasum" {
	# The stock-macOS case: no coreutils, so this is the tier that keeps a Mac
	# off the 14.51 ms Perl path.
	[ "$(_derive_with_tiers openssl shasum)" = "bbbbbbbbbbbb" ]
}

@test "falls to shasum only when both faster tiers are absent" {
	[ "$(_derive_with_tiers shasum)" = "cccccccccccc" ]
}

@test "fails rather than inventing a key when no hash tool exists" {
	run _derive_with_tiers
	[ "$status" -ne 0 ] || return 1
	[ -z "$output" ]
}

@test "every tier derives the same key as the others" {
	# The reordering is safe only because the tiers agree. If they ever did
	# not, moving one ahead of another would silently repartition every
	# $ONLOOKER_DIR/<plugin>/<key>/ directory on the machine.
	local input="remote:git@github.com:org/fixture.git"
	local by_sum by_ssl by_sha
	command -v sha256sum >/dev/null 2>&1 \
		&& by_sum=$(printf '%s' "$input" | sha256sum | cut -c1-12)
	command -v openssl >/dev/null 2>&1 \
		&& by_ssl=$(printf '%s' "$input" | openssl dgst -sha256 | sed 's/^.*= *//' | cut -c1-12)
	command -v shasum >/dev/null 2>&1 \
		&& by_sha=$(printf '%s' "$input" | shasum -a 256 | cut -c1-12)

	# Whichever tiers this machine has must agree with the function's answer.
	local actual
	actual=$(_onlooker_sha256_first12 "$input")
	[[ "$actual" =~ ^[0-9a-f]{12}$ ]] || return 1
	[[ -z "$by_sum" || "$by_sum" == "$actual" ]] || return 1
	[[ -z "$by_ssl" || "$by_ssl" == "$actual" ]] || return 1
	[[ -z "$by_sha" || "$by_sha" == "$actual" ]] || return 1
	# At least one tier had to be present for this to have proved anything.
	[ -n "${by_sum}${by_ssl}${by_sha}" ]
}

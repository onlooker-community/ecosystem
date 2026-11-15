#!/usr/bin/env bats

# Glob matching for the Stop-time nudge (docs/superpowers/specs/
# 2026-11-15-tribunal-nudge-design.md, "Glob matching"). No globstar: macOS
# /bin/bash is 3.2 and has none, and `**/x/**` under [[ == ]] misses a
# root-level x/. Each case also runs under /bin/bash when that is a 3.2,
# because CI runs bash 5 and would never see a 3.2-only break.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	LIB="${REPO_ROOT}/plugins/tribunal/scripts/lib/tribunal-nudge.sh"
	# shellcheck source=../../plugins/tribunal/scripts/lib/tribunal-nudge.sh
	source "$LIB"
}

# _match_in <bash> <path> <glob> — run the matcher under a given interpreter.
_match_in() {
	"$1" -c 'source "$1"; tribunal_nudge_matches_any "$2" "$3"' _ "$LIB" "$2" "$3"
}

@test "**/ matches zero or more leading directories" {
	tribunal_nudge_matches_any "migrations/1.sql" "**/migrations/**" || return 1
	tribunal_nudge_matches_any "db/migrations/1.sql" "**/migrations/**" || return 1
	tribunal_nudge_matches_any "a/b/migrations/x/y.sql" "**/migrations/**"
}

@test "* stays inside one path segment" {
	tribunal_nudge_matches_any "plugins/x/hooks/a.sh" "plugins/*/hooks/*.sh" || return 1
	! tribunal_nudge_matches_any "plugins/x/y/hooks/a.sh" "plugins/*/hooks/*.sh"
}

@test "regex metacharacters in a glob are literal" {
	tribunal_nudge_matches_any ".github/workflows/ci.yml" ".github/workflows/**" || return 1
	! tribunal_nudge_matches_any "xgithub/workflows/ci.yml" ".github/workflows/**" || return 1
	tribunal_nudge_matches_any "c++/a.h" "c++/*.h" || return 1
	! tribunal_nudge_matches_any "ccc/a.h" "c++/*.h"
}

@test "the match is anchored at both ends" {
	! tribunal_nudge_matches_any "src/auth/x.ts.bak/deep" "src/auth/*.ts" || return 1
	! tribunal_nudge_matches_any "vendor/.github/workflows/ci.yml" ".github/workflows/**"
}

@test "matching ignores case, and leaves nocasematch as it found it" {
	tribunal_nudge_matches_any "docs/Secrets.md" "**/*secret*" || return 1
	tribunal_nudge_matches_any "config/.ENV" "**/.env*" || return 1
	shopt -u nocasematch
	tribunal_nudge_matches_any "A.md" "a.md" || return 1
	! shopt -q nocasematch
}

@test "no glob matches nothing" {
	! tribunal_nudge_matches_any "a.txt"
}

@test "the same cases hold under /bin/bash 3.2" {
	[[ -x /bin/bash ]] || skip "no /bin/bash"
	[[ "$(/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}"')" == "3" ]] || skip "/bin/bash is not 3.2"
	_match_in /bin/bash "migrations/1.sql" "**/migrations/**" || return 1
	_match_in /bin/bash "docs/Secrets.md" "**/*secret*" || return 1
	! _match_in /bin/bash "plugins/x/y/hooks/a.sh" "plugins/*/hooks/*.sh"
}

#!/usr/bin/env bats
# Watch-unmatched signal (ecosystem-449.21).
#
# The governing rule under test: each mode mirrors its plugin's real matcher.
# A check that disagrees with the matcher invents misconfigurations that are
# not there, which is worse than the silence it replaces.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/scripts/lib/watch-unmatched.sh"
	MARKER=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
}

@test "marker path is project-scoped and under ONLOOKER_DIR" {
	[[ "$MARKER" == "${ONLOOKER_DIR}/watch-unmatched/proj123/echo.watch_paths.json" ]]
}

# Guards the fallback. Echo calls this above the point where its own hook
# establishes ONLOOKER_BASE, so an unset ONLOOKER_DIR must still yield a
# writable path rather than one rooted at "/".
@test "marker path falls back to HOME when ONLOOKER_DIR is unset" {
	saved="$ONLOOKER_DIR"
	unset ONLOOKER_DIR
	path=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	export ONLOOKER_DIR="$saved"
	[[ "$path" == "${HOME}/.onlooker/watch-unmatched/proj123/echo.watch_paths.json" ]]
}

@test "patterns hash ignores ordering but not content" {
	a=$(onlooker_watch_patterns_hash '["b.md","a.md"]')
	b=$(onlooker_watch_patterns_hash '["a.md","b.md"]')
	c=$(onlooker_watch_patterns_hash '["a.md","c.md"]')
	[[ -n "$a" && "$a" == "$b" && "$a" != "$c" ]]
}

@test "an absent marker is due" {
	onlooker_watch_marker_due "$MARKER" "abc123abc123" 168
}

@test "a fresh marker with a matching hash is not due" {
	onlooker_watch_marker_write "$MARKER" "abc123abc123"
	! onlooker_watch_marker_due "$MARKER" "abc123abc123" 168
}

@test "a changed hash re-arms a fresh marker" {
	onlooker_watch_marker_write "$MARKER" "abc123abc123"
	onlooker_watch_marker_due "$MARKER" "def456def456" 168
}

@test "an expired marker is due even when the hash matches" {
	mkdir -p "$(dirname "$MARKER")"
	jq -n --arg h "abc123abc123" --arg t "$(relative_iso_days_ago 8)" \
		'{patterns_hash: $h, last_emitted: $t}' >"$MARKER"
	onlooker_watch_marker_due "$MARKER" "abc123abc123" 168
}

@test "a corrupt marker is due rather than trusted" {
	mkdir -p "$(dirname "$MARKER")"
	printf 'not json' >"$MARKER"
	onlooker_watch_marker_due "$MARKER" "abc123abc123" 168
}

@test "clearing removes the marker and is safe when absent" {
	onlooker_watch_marker_write "$MARKER" "abc123abc123"
	onlooker_watch_marker_clear "$MARKER"
	[[ ! -f "$MARKER" ]]
	onlooker_watch_marker_clear "$MARKER"
}

_make_repo() {
	FIXTURE="${BATS_TEST_TMPDIR}/fixture"
	mkdir -p "${FIXTURE}/plugins/demo/agents"
	git -C "$FIXTURE" init -q
	git -C "$FIXTURE" config user.email t@example.com
	git -C "$FIXTURE" config user.name "Test"
	printf '# agent\n' >"${FIXTURE}/plugins/demo/agents/one.md"
	printf '# readme\n' >"${FIXTURE}/README.md"
	git -C "$FIXTURE" add -A
	git -C "$FIXTURE" commit -qm "fixture"
}

@test "files scanner matches a pattern that hits a tracked file" {
	_make_repo
	result=$(_onlooker_watch_scan_files "$FIXTURE" '["plugins/*/agents/*.md"]')
	[[ "${result%% *}" == "1" ]]
}

@test "files scanner reports zero for a pattern that hits nothing" {
	_make_repo
	result=$(_onlooker_watch_scan_files "$FIXTURE" '["nope/*/never.md"]')
	[[ "${result%% *}" == "0" ]]
	[[ "${result##* }" -ge 2 ]]
}

@test "files scanner ignores untracked files" {
	_make_repo
	printf '# untracked\n' >"${FIXTURE}/plugins/demo/agents/two.txt"
	result=$(_onlooker_watch_scan_files "$FIXTURE" '["plugins/*/agents/*.txt"]')
	[[ "${result%% *}" == "0" ]]
}

@test "files scanner is safe on a non-repo root" {
	mkdir -p "${BATS_TEST_TMPDIR}/plain"
	result=$(_onlooker_watch_scan_files "${BATS_TEST_TMPDIR}/plain" '["*.md"]')
	[[ "${result%% *}" == "0" ]]
}

@test "dirs scanner matches a glob that hits a real directory" {
	_make_repo
	result=$(_onlooker_watch_scan_dirs "$FIXTURE" '["plugins/*/"]')
	[[ "${result%% *}" == "1" ]]
}

@test "dirs scanner reports zero for a glob that hits nothing" {
	_make_repo
	result=$(_onlooker_watch_scan_dirs "$FIXTURE" '["nonexistent/*/"]')
	[[ "${result%% *}" == "0" ]]
}

# The divergence that forces two scanners rather than one. Cartographer expands
# against the filesystem, so it sees what git does not. A git ls-files check
# would call this unmatched and invent a misconfiguration.
@test "dirs scanner sees untracked directories, unlike the files scanner" {
	_make_repo
	mkdir -p "${FIXTURE}/untracked-dir/child"
	dirs_result=$(_onlooker_watch_scan_dirs "$FIXTURE" '["untracked-dir/*/"]')
	files_result=$(_onlooker_watch_scan_files "$FIXTURE" '["untracked-dir/*"]')
	[[ "${dirs_result%% *}" == "1" ]]
	[[ "${files_result%% *}" == "0" ]]
}

@test "dirs scanner restores the caller's nullglob setting" {
	_make_repo
	shopt -u nullglob
	_onlooker_watch_scan_dirs "$FIXTURE" '["plugins/*/"]' >/dev/null
	! shopt -q nullglob
}

@test "dirs scanner handles a root containing a space" {
	SPACED="${BATS_TEST_TMPDIR}/has space"
	mkdir -p "${SPACED}/plugins/demo"
	result=$(_onlooker_watch_scan_dirs "$SPACED" '["plugins/*/"]')
	[[ "${result%% *}" == "1" ]]
}

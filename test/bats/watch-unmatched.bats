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

_fake_emit() {
	printf '%s\t%s\n' "$1" "$2" >>"${BATS_TEST_TMPDIR}/emitted"
}

_emitted_count() {
	[[ -f "${BATS_TEST_TMPDIR}/emitted" ]] && wc -l <"${BATS_TEST_TMPDIR}/emitted" | tr -d ' ' || printf '0'
}

_check() {
	onlooker_watch_unmatched_check \
		--plugin echo --config-key echo.watch_paths \
		--root "$FIXTURE" --project-key "proj123" \
		--mode files --patterns-json "$1" \
		--emit-fn _fake_emit "${@:2}"
}

@test "emits when patterns match nothing" {
	_make_repo
	_check '["nope/*.md"]'
	[[ "$(_emitted_count)" == "1" ]]
	grep -q 'onlooker.watch.unmatched' "${BATS_TEST_TMPDIR}/emitted"
}

@test "the payload carries exactly the fields the schema allows" {
	_make_repo
	_check '["nope/*.md"]'
	payload=$(cut -f2 <"${BATS_TEST_TMPDIR}/emitted")
	printf '%s' "$payload" | jq -e '
		.plugin == "echo"
		and .config_key == "echo.watch_paths"
		and .patterns == ["nope/*.md"]
		and .project_key == "proj123"
		and (.candidates_scanned | type) == "number"
		and ([keys[]] | sort) == ["candidates_scanned","config_key","patterns","plugin","project_key"]
	' >/dev/null
}

@test "does not emit when patterns match" {
	_make_repo
	_check '["plugins/*/agents/*.md"]'
	[[ "$(_emitted_count)" == "0" ]]
}

@test "a match clears an existing marker" {
	_make_repo
	marker=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	onlooker_watch_marker_write "$marker" "stale-hash-xx"
	_check '["plugins/*/agents/*.md"]'
	[[ ! -f "$marker" ]]
}

# MUTATION TEST. A test asserting "no second event" passes just as well when
# the emitter is broken outright, so the first emit is asserted in the same
# test. Break the suppression and this must fail, or it is decoration.
@test "a second call is suppressed by the marker but the first still emitted" {
	_make_repo
	_check '["nope/*.md"]'
	[[ "$(_emitted_count)" == "1" ]]
	_check '["nope/*.md"]'
	[[ "$(_emitted_count)" == "1" ]]
}

# THE COST CONTRACT. When the marker says the check is not due, the scanner must
# not run at all -- that is what makes the steady state one stat on a hook that
# fires on every Stop. Proven by its side effect: a matching repo would clear the
# marker if it were scanned, so the marker surviving proves no scan happened.
@test "a marker that is not due suppresses the scan entirely" {
	_make_repo
	marker=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	hash=$(onlooker_watch_patterns_hash '["plugins/*/agents/*.md"]')
	onlooker_watch_marker_write "$marker" "$hash"
	_check '["plugins/*/agents/*.md"]'
	[[ -f "$marker" ]]
	[[ "$(_emitted_count)" == "0" ]]
}

@test "a changed pattern set re-arms the signal" {
	_make_repo
	_check '["nope/*.md"]'
	_check '["also-nope/*.md"]'
	[[ "$(_emitted_count)" == "2" ]]
}

@test "an expired marker re-arms the signal" {
	_make_repo
	_check '["nope/*.md"]'
	marker=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	hash=$(onlooker_watch_patterns_hash '["nope/*.md"]')
	jq -n --arg h "$hash" --arg t "$(relative_iso_days_ago 8)" \
		'{patterns_hash: $h, last_emitted: $t}' >"$marker"
	_check '["nope/*.md"]'
	[[ "$(_emitted_count)" == "2" ]]
}

@test "returns 0 and emits nothing when required arguments are missing" {
	run onlooker_watch_unmatched_check --plugin echo --emit-fn _fake_emit
	[ "$status" -eq 0 ]
	[[ "$(_emitted_count)" == "0" ]]
}

@test "returns 0 when the emit function does not exist" {
	_make_repo
	run onlooker_watch_unmatched_check \
		--plugin echo --config-key echo.watch_paths \
		--root "$FIXTURE" --project-key "proj123" \
		--mode files --patterns-json '["nope/*.md"]' \
		--emit-fn no_such_function
	[ "$status" -eq 0 ]
}

@test "an empty pattern list emits nothing" {
	_make_repo
	_check '[]'
	[[ "$(_emitted_count)" == "0" ]]
}

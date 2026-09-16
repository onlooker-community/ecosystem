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

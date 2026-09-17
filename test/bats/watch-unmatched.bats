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

	if command -v timeout >/dev/null 2>&1; then
		TIMEOUT_BIN="timeout"
	elif command -v gtimeout >/dev/null 2>&1; then
		TIMEOUT_BIN="gtimeout"
	else
		TIMEOUT_BIN=""
	fi
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

@test "files scanner matches untracked-but-not-ignored files" {
	_make_repo
	printf '# untracked\n' >"${FIXTURE}/plugins/demo/agents/two.txt"
	result=$(_onlooker_watch_scan_files "$FIXTURE" '["plugins/*/agents/*.txt"]')
	[[ "${result%% *}" == "1" ]]
}

@test "files scanner does not match a gitignored file" {
	_make_repo
	printf 'secrets/\n' >"${FIXTURE}/.gitignore"
	mkdir -p "${FIXTURE}/secrets"
	printf 'shh\n' >"${FIXTURE}/secrets/token.md"
	run git -C "$FIXTURE" check-ignore -q "secrets/token.md"
	[ "$status" -eq 0 ]
	result=$(_onlooker_watch_scan_files "$FIXTURE" '["secrets/*.md"]')
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
# against the filesystem with no concept of .gitignore, so it sees paths git
# excludes. The files scanner now mirrors echo's real candidate set (tracked
# plus untracked-but-not-ignored), so untracked-but-not-ignored paths no
# longer discriminate the two modes -- both see those. Gitignored paths are
# the boundary that remains: a files-mode check would call this unmatched and
# invent a misconfiguration.
@test "dirs scanner sees gitignored paths, unlike the files scanner" {
	_make_repo
	printf 'ignored-dir/\n' >"${FIXTURE}/.gitignore"
	mkdir -p "${FIXTURE}/ignored-dir/child"
	printf '# ignored\n' >"${FIXTURE}/ignored-dir/child/note.md"
	run git -C "$FIXTURE" check-ignore -q "ignored-dir/child/note.md"
	[ "$status" -eq 0 ]

	dirs_result=$(_onlooker_watch_scan_dirs "$FIXTURE" '["ignored-dir/*/"]')
	files_result=$(_onlooker_watch_scan_files "$FIXTURE" '["ignored-dir/*"]')
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

# `shift 2` is a no-op in bash when only one positional parameter remains:
# positional params are unchanged and the shift call itself fails, so a
# value-taking flag appearing LAST with no value spun the parser loop forever.
# Verified empirically before the fix: the equivalent loop given `f --plugin`
# alone hit a 3s timeout (exit 124). Each case below runs under `timeout` for
# exactly that reason -- a regression here must fail the test, not hang the
# whole suite. A sentinel emit function proves the early return happened for
# the right reason (a required field went missing), not merely that nothing
# crashed.
_missing_value_call() {
	"$TIMEOUT_BIN" 5 bash -c "
		source '${REPO_ROOT}/scripts/lib/watch-unmatched.sh'
		_sentinel_emit() { printf 'emitted' >>'${BATS_TEST_TMPDIR}/sentinel'; }
		onlooker_watch_unmatched_check $1
	"
}

@test "a trailing value-less --plugin returns 0 without hanging" {
	[[ -z "$TIMEOUT_BIN" ]] && skip "no timeout/gtimeout binary available"
	run _missing_value_call "--emit-fn _sentinel_emit --plugin"
	[ "$status" -eq 0 ]
	[ ! -f "${BATS_TEST_TMPDIR}/sentinel" ]
}

@test "a trailing value-less --config-key returns 0 without hanging" {
	[[ -z "$TIMEOUT_BIN" ]] && skip "no timeout/gtimeout binary available"
	run _missing_value_call "--emit-fn _sentinel_emit --config-key"
	[ "$status" -eq 0 ]
	[ ! -f "${BATS_TEST_TMPDIR}/sentinel" ]
}

@test "a trailing value-less --root returns 0 without hanging" {
	[[ -z "$TIMEOUT_BIN" ]] && skip "no timeout/gtimeout binary available"
	run _missing_value_call "--emit-fn _sentinel_emit --root"
	[ "$status" -eq 0 ]
	[ ! -f "${BATS_TEST_TMPDIR}/sentinel" ]
}

@test "a trailing value-less --project-key returns 0 without hanging" {
	[[ -z "$TIMEOUT_BIN" ]] && skip "no timeout/gtimeout binary available"
	run _missing_value_call "--emit-fn _sentinel_emit --project-key"
	[ "$status" -eq 0 ]
	[ ! -f "${BATS_TEST_TMPDIR}/sentinel" ]
}

@test "a trailing value-less --mode returns 0 without hanging" {
	[[ -z "$TIMEOUT_BIN" ]] && skip "no timeout/gtimeout binary available"
	run _missing_value_call "--emit-fn _sentinel_emit --mode"
	[ "$status" -eq 0 ]
	[ ! -f "${BATS_TEST_TMPDIR}/sentinel" ]
}

@test "a trailing value-less --patterns-json returns 0 without hanging" {
	[[ -z "$TIMEOUT_BIN" ]] && skip "no timeout/gtimeout binary available"
	run _missing_value_call "--emit-fn _sentinel_emit --patterns-json"
	[ "$status" -eq 0 ]
	[ ! -f "${BATS_TEST_TMPDIR}/sentinel" ]
}

@test "a trailing value-less --emit-fn returns 0 without hanging" {
	[[ -z "$TIMEOUT_BIN" ]] && skip "no timeout/gtimeout binary available"
	run _missing_value_call "--emit-fn"
	[ "$status" -eq 0 ]
	[ ! -f "${BATS_TEST_TMPDIR}/sentinel" ]
}

@test "a trailing value-less --ttl-hours returns 0 without hanging" {
	[[ -z "$TIMEOUT_BIN" ]] && skip "no timeout/gtimeout binary available"
	run _missing_value_call "--emit-fn _sentinel_emit --ttl-hours"
	[ "$status" -eq 0 ]
	[ ! -f "${BATS_TEST_TMPDIR}/sentinel" ]
}

# The property that actually matters here is not the return code -- that is
# already guaranteed independently by the trailing `return 0`. What must NOT
# happen is the marker getting written: if the emit-fn guard were bypassed, a
# typo'd --emit-fn would arm the marker as "handled" for a full TTL with
# nothing ever emitted, which is exactly the silent-failure mode this feature
# exists to eliminate.
@test "returns 0 when the emit function does not exist" {
	_make_repo
	marker=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	run onlooker_watch_unmatched_check \
		--plugin echo --config-key echo.watch_paths \
		--root "$FIXTURE" --project-key "proj123" \
		--mode files --patterns-json '["nope/*.md"]' \
		--emit-fn no_such_function
	[ "$status" -eq 0 ]
	[[ ! -f "$marker" ]]
}

@test "an empty pattern list emits nothing" {
	_make_repo
	_check '[]'
	[[ "$(_emitted_count)" == "0" ]]
}

# candidates_scanned is a deliberate omission in dirs mode, not an accident --
# nullglob makes an unmatched glob produce a real, always-zero iteration count,
# which would look like a measurement while never varying. This must fail if
# that omission is ever reversed, so it asserts absence of the key (not that
# it equals 0 or null), and pairs it with files mode still carrying the key so
# the two modes discriminate.
@test "dirs mode omits candidates_scanned while files mode still carries it" {
	_make_repo
	onlooker_watch_unmatched_check \
		--plugin cartographer --config-key cartographer.watch_globs \
		--root "$FIXTURE" --project-key "proj123" \
		--mode dirs --patterns-json '["nonexistent/*/"]' \
		--emit-fn _fake_emit
	dirs_payload=$(tail -n1 "${BATS_TEST_TMPDIR}/emitted" | cut -f2)
	printf '%s' "$dirs_payload" | jq -e '(has("candidates_scanned") | not)' >/dev/null

	_check '["nope/*.md"]'
	files_payload=$(tail -n1 "${BATS_TEST_TMPDIR}/emitted" | cut -f2)
	printf '%s' "$files_payload" | jq -e 'has("candidates_scanned")' >/dev/null
}

@test "an unknown mode emits nothing" {
	_make_repo
	run onlooker_watch_unmatched_check \
		--plugin echo --config-key echo.watch_paths \
		--root "$FIXTURE" --project-key "proj123" \
		--mode bogus --patterns-json '["nope/*.md"]' \
		--emit-fn _fake_emit
	[ "$status" -eq 0 ]
	[[ "$(_emitted_count)" == "0" ]]
}

@test "malformed patterns JSON emits nothing" {
	_make_repo
	run onlooker_watch_unmatched_check \
		--plugin echo --config-key echo.watch_paths \
		--root "$FIXTURE" --project-key "proj123" \
		--mode files --patterns-json 'not-json' \
		--emit-fn _fake_emit
	[ "$status" -eq 0 ]
	[[ "$(_emitted_count)" == "0" ]]
}

# A marker-write failure must not take the emit down with it: the event
# already reached the emit-fn before the marker write is attempted, so a
# read-only marker directory should still leave the caller with a delivered
# event and a clean return code.
@test "a marker-write failure still emits and returns 0" {
	_make_repo
	marker=$(onlooker_watch_marker_path "proj123" "echo.watch_paths")
	mkdir -p "$(dirname "$marker")"
	chmod 500 "$(dirname "$marker")"
	run _check '["nope/*.md"]'
	chmod 700 "$(dirname "$marker")"
	[ "$status" -eq 0 ]
	[[ "$(_emitted_count)" == "1" ]]
}

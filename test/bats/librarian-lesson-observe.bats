#!/usr/bin/env bats
# librarian_lesson_observe: a stack entry's version, read from the project at
# the session's commit, from a component's home repo, or from a probe of the
# machine. No model call, and nothing written.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-observe.sh"

	KEY="aaaaaaaaaaaa"
	REPO="${BATS_TEST_TMPDIR}/project"
	_init_repo "$REPO"
	_register "$KEY" "$REPO"

	# Two commits: the session ran between them, so the first is the one
	# that counts and the second must be ignored.
	OLD=$(relative_iso_days_ago 10)
	SESSION=$(relative_iso_days_ago 5)
	NEW=$(relative_iso_days_ago 2)

	_write "$REPO" package-lock.json '{"packages":{"":{},"node_modules/vite":{"version":"5.4.21"},"node_modules/@cloudflare/vite-plugin":{"version":"1.42.0"}}}'
	_write "$REPO" package.json '{"name":"fixture","dependencies":{"react":"^18.2.0"}}'
	_write "$REPO" mise.toml $'[tools]\nbats = "1.12.0"\n"aqua:BurntSushi/ripgrep" = "15.1.0"\n'
	_write "$REPO" .github/workflows/release.yml $'jobs:\n  r:\n    steps:\n      - uses: googleapis/release-please-action@v4\n'
	_write "$REPO" plugins/fixture-plugin/.claude-plugin/plugin.json '{"name":"fixture-plugin","version":"0.3.1"}'
	_commit "$REPO" "$OLD"

	_write "$REPO" package-lock.json '{"packages":{"":{},"node_modules/vite":{"version":"6.0.0"}}}'
	_commit "$REPO" "$NEW"
}

_init_repo() {
	mkdir -p "$1"
	git -C "$1" init -q
	git -C "$1" config user.email t@example.com
	git -C "$1" config user.name Test
}

_register() {
	mkdir -p "${ONLOOKER_DIR}/librarian/$1"
	jq -n --arg k "$1" --arg r "$2" '{project_key: $k, repo_root: $r}' \
		> "${ONLOOKER_DIR}/librarian/$1/manifest.json"
}

_write() {
	mkdir -p "$(dirname "$1/$2")"
	printf '%s' "$3" > "$1/$2"
}

_commit() {
	git -C "$1" add -A
	GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" git -C "$1" commit -q -m c
}

_observe() {
	librarian_lesson_observe "$KEY" "$SESSION" "$1"
}

@test "a lockfile version is read at the session's commit, not HEAD" {
	run _observe '["vite"]'
	[ "$status" -eq 0 ] || return 1
	printf '%s' "$output" | jq -e '.observed_on.vite == {version: "5.4.21", source: "lockfile", basis: "session_commit"} and .unresolved == []' >/dev/null
}

@test "a scoped package name is matched as written" {
	run _observe '["@cloudflare/vite-plugin"]'
	printf '%s' "$output" | jq -e '.observed_on["@cloudflare/vite-plugin"].version == "1.42.0"' >/dev/null
}

@test "names are matched without case or a .js suffix" {
	run _observe '["Vite.js"]'
	printf '%s' "$output" | jq -e '.observed_on["Vite.js"].version == "5.4.21"' >/dev/null
}

@test "a session before the first commit falls back to HEAD and says so" {
	run librarian_lesson_observe "$KEY" "$(relative_iso_days_ago 30)" '["vite"]'
	printf '%s' "$output" | jq -e '.observed_on.vite == {version: "6.0.0", source: "lockfile", basis: "head"}' >/dev/null
}

@test "a mise pin is read, including a backend-prefixed tool" {
	run _observe '["bats", "ripgrep"]'
	printf '%s' "$output" | jq -e '.observed_on.bats == {version: "1.12.0", source: "mise", basis: "session_commit"} and .observed_on.ripgrep.version == "15.1.0"' >/dev/null
}

@test "a workflow action pin versions the action, without its -action suffix" {
	run _observe '["release-please"]'
	printf '%s' "$output" | jq -e '.observed_on["release-please"] == {version: "4", source: "workflow", basis: "session_commit"}' >/dev/null
}

@test "the project's own plugin is a component" {
	run _observe '["fixture-plugin"]'
	printf '%s' "$output" | jq -e '.observed_on["fixture-plugin"] == {version: "0.3.1", source: "component", basis: "session_commit"}' >/dev/null
}

@test "a dependency with no lockfile entry keeps its declared range" {
	run _observe '["react"]'
	printf '%s' "$output" | jq -e '.observed_on.react == {version: "^18.2.0", source: "manifest", basis: "session_commit"}' >/dev/null
}

@test "a component from another registered repo is read at its own commit" {
	OTHER="${BATS_TEST_TMPDIR}/other"
	_init_repo "$OTHER"
	_register "bbbbbbbbbbbb" "$OTHER"
	_write "$OTHER" plugins/tribunal/.claude-plugin/plugin.json '{"name":"tribunal","version":"1.2.3"}'
	_commit "$OTHER" "$OLD"
	_write "$OTHER" plugins/tribunal/.claude-plugin/plugin.json '{"name":"tribunal","version":"2.0.0"}'
	_commit "$OTHER" "$NEW"

	run _observe '["tribunal"]'
	printf '%s' "$output" | jq -e '.observed_on.tribunal == {version: "1.2.3", source: "component", basis: "session_commit"}' >/dev/null
}

@test "a resolved gem is read from Gemfile.lock, not its dependency constraints" {
	_write "$REPO" Gemfile.lock $'GEM\n  remote: https://rubygems.org/\n  specs:\n    rails (7.1.3)\n      rack (>= 2.2.4)\n    rack (3.0.9)\n'
	_commit "$REPO" "$(relative_iso_days_ago 6)"
	run _observe '["rails", "rack"]'
	printf '%s' "$output" | jq -e '.observed_on.rails.version == "7.1.3" and .observed_on.rack.version == "3.0.9"' >/dev/null
}

@test "a Python package is read from uv.lock" {
	_write "$REPO" uv.lock $'version = 1\n\n[[package]]\nname = "httpx"\nversion = "0.27.0"\nsource = { registry = "https://pypi.org/simple" }\n'
	_commit "$REPO" "$(relative_iso_days_ago 6)"
	run _observe '["httpx"]'
	printf '%s' "$output" | jq -e '.observed_on.httpx == {version: "0.27.0", source: "lockfile", basis: "session_commit"}' >/dev/null
}

@test "an entry no source knows is unresolved" {
	run _observe '["vite", "Sentry"]'
	printf '%s' "$output" | jq -e '(.observed_on | keys) == ["vite"] and .unresolved == ["Sentry"]' >/dev/null
}

@test "an unregistered project leaves every entry unresolved" {
	run librarian_lesson_observe "cccccccccccc" "$SESSION" '["vite"]'
	[ "$status" -eq 0 ] || return 1
	printf '%s' "$output" | jq -e '.observed_on == {} and .unresolved == ["vite"]' >/dev/null
}

@test "a working-tree edit is never read" {
	_write "$REPO" package-lock.json '{"packages":{"node_modules/vite":{"version":"9.9.9"}}}'
	run _observe '["vite"]'
	printf '%s' "$output" | jq -e '.observed_on.vite.version == "5.4.21"' >/dev/null
}

@test "a missing argument prints nothing" {
	run librarian_lesson_observe "$KEY" "" '["vite"]'
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ]
}

@test "nothing is written to the librarian store" {
	before=$(find "${ONLOOKER_DIR}" -type f | sort)
	run _observe '["vite", "Sentry"]'
	[ "$(find "${ONLOOKER_DIR}" -type f | sort)" = "$before" ]
}

@test "a non-string stack element is unresolved and does not void the rest" {
	run _observe '["vite", 1, null]'
	[ "$status" -eq 0 ] || return 1
	[ -n "$output" ] || return 1
	printf '%s' "$output" | jq -e '.observed_on.vite.version == "5.4.21" and .unresolved == [1, null]' >/dev/null
}

_stub() {
	mkdir -p "${BATS_TEST_TMPDIR}/stub"
	printf '#!/usr/bin/env bash\n%s\n' "$2" > "${BATS_TEST_TMPDIR}/stub/$1"
	chmod +x "${BATS_TEST_TMPDIR}/stub/$1"
}

_observe_stubbed() {
	PATH="${BATS_TEST_TMPDIR}/stub:${PATH}" librarian_lesson_observe "$KEY" "$SESSION" "$1"
}

@test "a tool on the allowlist is probed when no manifest has it" {
	_stub sqlite3 'echo "3.43.2 2023-10-10 13:08:14 abc"'
	run _observe_stubbed '["sqlite3"]'
	printf '%s' "$output" | jq -e '.observed_on.sqlite3 == {version: "3.43.2", source: "probe", basis: "machine"}' >/dev/null
}

@test "sqlite is probed under either name" {
	_stub sqlite3 'echo "3.43.2 2023-10-10"'
	run _observe_stubbed '["SQLite"]'
	printf '%s' "$output" | jq -e '.observed_on.SQLite.version == "3.43.2"' >/dev/null
}

@test "a GNU awk is recorded with its flavor" {
	_stub awk 'echo "GNU Awk 5.3.0, API 4.0"'
	run _observe_stubbed '["awk"]'
	printf '%s' "$output" | jq -e '.observed_on.awk == {version: "5.3.0", source: "probe", basis: "machine", flavor: "gnu"}' >/dev/null
}

@test "a BSD awk's date-shaped version is kept" {
	_stub awk 'echo "awk version 20200816"'
	run _observe_stubbed '["awk"]'
	printf '%s' "$output" | jq -e '.observed_on.awk == {version: "20200816", source: "probe", basis: "machine", flavor: "bsd"}' >/dev/null
}

@test "a probe that fails leaves the entry unresolved" {
	_stub npm 'exit 1'
	run _observe_stubbed '["npm"]'
	printf '%s' "$output" | jq -e '.unresolved == ["npm"]' >/dev/null
}

@test "a tool off the allowlist is never run" {
	_stub vitest 'touch "'"${BATS_TEST_TMPDIR}"'/ran"; echo "vitest/9.0.0"'
	run _observe_stubbed '["vitest"]'
	[ ! -e "${BATS_TEST_TMPDIR}/ran" ] || return 1
	printf '%s' "$output" | jq -e '.unresolved == ["vitest"]' >/dev/null
}

@test "a manifest pin wins over the probe" {
	_stub bats 'echo "Bats 9.9.9"'
	run _observe_stubbed '["bats"]'
	printf '%s' "$output" | jq -e '.observed_on.bats.source == "mise"' >/dev/null
}

@test "BSD grep is told apart from GNU grep by what its version line says" {
	_stub grep 'echo "grep (BSD grep, GNU compatible) 2.6.0-FreeBSD"'
	run _observe_stubbed '["grep"]'
	printf '%s' "$output" | jq -e '.observed_on.grep == {version: "2.6.0", source: "probe", basis: "machine", flavor: "bsd"}' >/dev/null
}

@test "GNU grep is recorded as gnu" {
	_stub grep 'echo "grep (GNU grep) 3.11"'
	run _observe_stubbed '["grep"]'
	printf '%s' "$output" | jq -e '.observed_on.grep == {version: "3.11", source: "probe", basis: "machine", flavor: "gnu"}' >/dev/null
}

@test "macOS is read from sw_vers, not the Darwin kernel" {
	_stub sw_vers 'echo "26.1"'
	run _observe_stubbed '["macos"]'
	printf '%s' "$output" | jq -e '.observed_on.macos.version == "26.1"' >/dev/null
}

@test "darwin is still read from uname" {
	_stub uname 'echo "25.0.0"'
	run _observe_stubbed '["darwin"]'
	printf '%s' "$output" | jq -e '.observed_on.darwin.version == "25.0.0"' >/dev/null
}

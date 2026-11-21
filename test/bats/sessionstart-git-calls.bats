#!/usr/bin/env bats

# Every SessionStart hook asks git only what it has not already asked (ONL-292).
#
# Every plugin's SessionStart hooks start at the same moment, so each process
# one spawns costs ~1.7x what it does alone, and a git call is ~12ms alone. Two
# kinds of call answered a question the hook already had the answer to:
#
#   - `git remote get-url origin`, for a project key the shared cache under
#     $ONLOOKER_DIR already holds. The emitter has read it from there since the
#     cache landed; the hooks resolved it fresh.
#   - rev-parses in onlooker_project_repo_root and onlooker_worktree_root, for
#     roots config-loader's own rev-parse had just found for the same cwd.
#
# The lib tests pin the memo config-loader leaves for project-key: it must
# answer exactly what git would, from every kind of cwd, or a hook reads the
# wrong tree. The hook tests count every git call a hook makes, detached
# children included, against a warm project-key cache.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "${MAIN}/sub/dir"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email t@example.com
	git -C "$MAIN" config user.name "Test"
	git -C "$MAIN" remote add origin git@github.com:org/fixture.git
	git -C "$MAIN" commit -q --allow-empty -m init
	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch
	mkdir -p "${WT}/sub"
	PLAIN="${BATS_TEST_TMPDIR}/plain"
	mkdir -p "$PLAIN"

	GIT_LOG="${BATS_TEST_TMPDIR}/git-calls"
	: >"$GIT_LOG"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	local real_git
	real_git=$(command -v git)
	cat >"${STUB_BIN}/git" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$GIT_LOG"
exec "$real_git" "\$@"
STUB
	chmod +x "${STUB_BIN}/git"
	# Nothing here should reach a model: cartographer's background audit would
	# otherwise start a real `claude -p`.
	printf '#!/usr/bin/env bash\nexit 1\n' >"${STUB_BIN}/claude"
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_git_calls() { grep -c . "$GIT_LOG" || true; }

# What the two root functions answer for a cwd, with no memo in play: a fresh
# shell that sources project-key alone.
_roots_uncached() {
	bash -c 'source "$1"; printf "%s|%s" "$(onlooker_project_repo_root "$2")" "$(onlooker_worktree_root "$2")"' \
		_ "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh" "$1"
}

# The same answers after config-loader has resolved the same cwd, read the way
# hooks read them: through command substitution. Leaves the git calls the two
# root functions made in $GIT_LOG.
_roots_after_config_load() {
	bash -c '
		source "$1"; source "$2"
		export CLAUDE_PLUGIN_ROOT="$4"
		probe_config=""
		config_load_plugin probe "$3" probe_config
		: >"$5"
		printf "%s|%s" "$(onlooker_project_repo_root "$3")" "$(onlooker_worktree_root "$3")"
	' _ "${REPO_ROOT}/scripts/lib/config-loader.sh" "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh" \
		"$1" "${BATS_TEST_TMPDIR}/noplugin" "$GIT_LOG"
}

_assert_memo_matches_git() {
	local cwd="$1" want got
	want=$(_roots_uncached "$cwd")
	got=$(_roots_after_config_load "$cwd")
	[ "$got" = "$want" ] || { echo "cwd=$cwd want=$want got=$got"; return 1; }
	[ "$(_git_calls)" -eq 0 ] || { echo "cwd=$cwd made git calls:"; cat "$GIT_LOG"; return 1; }
}

@test "the shim counts a git call" {
	git -C "$MAIN" rev-parse HEAD >/dev/null
	[ "$(_git_calls)" -eq 1 ]
}

@test "after config load, the roots of a checkout's root come from the memo" {
	_assert_memo_matches_git "$MAIN"
}

@test "after config load, the roots of a checkout's subdirectory come from the memo" {
	_assert_memo_matches_git "${MAIN}/sub/dir"
}

@test "after config load, a linked worktree keeps itself and its parent apart" {
	_assert_memo_matches_git "$WT"
	# Not vacuous: the two roots differ here, so a memo that swapped them fails.
	[ "$(_roots_uncached "$WT")" = "$(cd "$MAIN" && pwd -P)|$(cd "$WT" && pwd -P)" ]
}

@test "after config load, a linked worktree's subdirectory comes from the memo" {
	_assert_memo_matches_git "${WT}/sub"
}

@test "after config load, a non-git directory still has no roots" {
	_assert_memo_matches_git "$PLAIN"
	[ "$(_roots_uncached "$PLAIN")" = "|" ]
}

@test "after config load, the .git directory still has no roots" {
	_assert_memo_matches_git "${MAIN}/.git"
}

@test "a memo for one cwd never answers for another" {
	run bash -c '
		source "$1"; source "$2"
		probe_config=""
		config_load_plugin probe "$3" probe_config
		printf "%s" "$(onlooker_worktree_root "$4")"
	' _ "${REPO_ROOT}/scripts/lib/config-loader.sh" "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh" \
		"$MAIN" "$WT"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "$(cd "$WT" && pwd -P)" ]
}

@test "repo_root with no memo asks git once" {
	source "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh"
	[ "$(onlooker_project_repo_root "${WT}/sub")" = "$(cd "$MAIN" && pwd -P)" ] || return 1
	[ "$(_git_calls)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

# The hook as hooks.json runs it, in a session whose project key is already
# cached, as it is in every session after a project's first. fd 9 is inherited
# by every child the hook detaches, and `cat` sees EOF on it only once the last
# of them exits, so the count includes their calls and never races them.
_git_calls_of() {
	local root="$1" hook="$2" payload
	source "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh"
	onlooker_project_resolve_cached "$MAIN"
	[ -n "$ONLOOKER_PROJECT_KEY" ] || return 1
	payload=$(jq -cn --arg cwd "$MAIN" \
		'{session_id: "sess-git", cwd: $cwd, hook_event_name: "SessionStart", source: "startup"}')
	: >"$GIT_LOG"
	{ CLAUDE_PLUGIN_ROOT="$root" bash "${root}/${hook}" <<<"$payload" >/dev/null 2>&1; } 9>&1 | cat >/dev/null
	_git_calls
}

@test "archivist-inject asks git once" {
	[ "$(_git_calls_of "${REPO_ROOT}/plugins/archivist" scripts/hooks/archivist-inject.sh)" -eq 1 ]
}

@test "bursar-session-start asks git once" {
	[ "$(_git_calls_of "${REPO_ROOT}/plugins/bursar" scripts/hooks/bursar-session-start.sh)" -eq 1 ]
}

# Once in the hook, and once in the audit it detaches, which a project with no
# prior audit always runs: the audit loads config from the resolved worktree
# root, a different string from the session cwd.
@test "cartographer-session-start asks git twice, its detached audit included" {
	[ "$(_git_calls_of "${REPO_ROOT}/plugins/cartographer" scripts/hooks/cartographer-session-start.sh)" -eq 2 ]
}

@test "librarian-session-start asks git once" {
	[ "$(_git_calls_of "${REPO_ROOT}/plugins/librarian" scripts/hooks/librarian-session-start.sh)" -eq 1 ]
}

@test "memory-recall-tracker never asks git" {
	[ "$(_git_calls_of "$REPO_ROOT" scripts/hooks/memory-recall-tracker.sh)" -eq 0 ]
}

# plugin-currency loads config from the repo root rather than the session cwd,
# so the two rev-parses are for different directories in a worktree and one
# memo cannot answer both.
@test "plugin-currency-surfacer asks git twice" {
	[ "$(_git_calls_of "$REPO_ROOT" scripts/hooks/plugin-currency-surfacer.sh)" -eq 2 ]
}

# The hook detaches its scan, and the child re-runs the script: one config load
# in each, plus the remote URL the child writes into the store's manifest.
@test "curator-session-start asks git three times, its detached scan included" {
	[ "$(_git_calls_of "${REPO_ROOT}/plugins/curator" scripts/hooks/curator-session-start.sh)" -eq 3 ]
}

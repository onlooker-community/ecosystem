#!/usr/bin/env bats
# Echo reporting that its watch_paths can never match (ecosystem-449.21).
#
# Distinct from echo.suite.skipped, which says "nothing to do this turn". This
# says "these patterns cannot match anything here, ever" -- a property of repo
# plus config rather than of the turn.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/echo-stop-gate.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${REPO}/agents" "${REPO}/.claude"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	printf '# Agent\n' >"${REPO}/agents/reviewer.md"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm init
}

_settings() {
	printf '%s\n' "$1" >"${REPO}/.claude/settings.json"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm settings
}

_run_hook() {
	run bash -c "printf '%s' '$(jq -cn --arg cwd "$REPO" \
		'{cwd: $cwd, session_id: "sess-watch", hook_event_name: "Stop"}')' | '$HOOK'"
}

# Strips whichever PATH entry resolves `claude`, leaving everything else (git,
# jq, etc.) intact. A dev sandbox running this suite from inside Claude Code
# has a real `claude` binary on PATH, so the sibling convention of pinning
# PATH to /usr/bin:/bin (echo-stop-hook.bats) is not usable here -- on this
# machine jq lives under a mise install directory, not /usr/bin, and that
# convention would take out the very tool the check under test depends on.
# A no-op when claude cannot be found at all (e.g. CI).
_path_without_claude() {
	local claude_bin claude_dir dir result=""
	claude_bin=$(command -v claude 2>/dev/null) || { printf '%s' "$PATH"; return; }
	claude_dir=$(dirname "$claude_bin")
	local IFS=:
	for dir in $PATH; do
		[[ "$dir" == "$claude_dir" ]] && continue
		result="${result:+$result:}${dir}"
	done
	printf '%s' "$result"
}

@test "reports when watch_paths can never match in this repo" {
	_settings '{"echo":{"watch_paths":["nowhere/*/never.md"]}}'
	_run_hook
	grep '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.plugin == "echo"
		         and .payload.config_key == "echo.watch_paths"
		         and .payload.patterns == ["nowhere/*/never.md"]' >/dev/null
}

# PLACEMENT CHECK. The hook returns at line 117 when nothing changed, before
# patterns are even loaded. A dead watcher in a quiet repo is exactly the case
# that must still report, so the check has to sit above that gate.
@test "reports even when the tree is clean and nothing changed" {
	_settings '{"echo":{"watch_paths":["nowhere/*/never.md"]}}'
	[ -z "$(git -C "$REPO" status --porcelain)" ]
	_run_hook
	grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

# PLACEMENT CHECK. `claude` is not on PATH in this suite, and the hook exits at
# line 87 when it is missing. The check must sit above that guard too: it needs
# only git and jq, and a user without claude installed still deserves to learn
# their config is dead.
@test "reports without claude on PATH" {
	_settings '{"echo":{"watch_paths":["nowhere/*/never.md"]}}'
	local restricted_path
	restricted_path=$(_path_without_claude)
	run env PATH="$restricted_path" command -v claude
	[ "$status" -ne 0 ]
	run env PATH="$restricted_path" bash -c "printf '%s' '$(jq -cn --arg cwd "$REPO" \
		'{cwd: $cwd, session_id: "sess-watch", hook_event_name: "Stop"}')' | '$HOOK'"
	grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "stays quiet when watch_paths match real files" {
	_settings '{"echo":{"watch_paths":["agents/*.md"]}}'
	_run_hook
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "emits once across two runs, not once per Stop" {
	_settings '{"echo":{"watch_paths":["nowhere/*/never.md"]}}'
	_run_hook
	_run_hook
	count=$(grep -c '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG")
	[[ "$count" == "1" ]]
}

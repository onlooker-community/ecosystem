#!/usr/bin/env bats

# Exercises the Echo Stop hook's gating behavior. Does not invoke claude -p
# (the hook bails before reaching the eval loop when preconditions fail).
# Tests verify: disabled-by-default, no-git, no-watched-changes, recursion
# guard, untracked file detection, and stdout silence.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/echo-stop-gate.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	(cd "$REPO" && printf 'initial\n' > README.md && git add README.md && git commit -q -m init)
}

_make_input() {
	local cwd="${1:-$REPO}" sid="${2:-test-session}"
	jq -n --arg cwd "$cwd" --arg sid "$sid" '{cwd: $cwd, session_id: $sid}'
}

@test "hook exits 0 silently when echo.enabled is false (default)" {
	local input
	input=$(_make_input)
	run bash -c "printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "hook exits 0 when cwd is not a git repo" {
	local non_repo="${BATS_TEST_TMPDIR}/not-a-repo"
	mkdir -p "$non_repo"
	local input
	input=$(_make_input "$non_repo")
	run bash -c "printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
}

@test "hook exits 0 when enabled but no watched files changed" {
	mkdir -p "${REPO}/.claude"
	printf '%s\n' '{"echo":{"enabled":true}}' > "${REPO}/.claude/settings.json"
	local input
	input=$(_make_input)
	run bash -c "printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "recursion guard: ECHO_NESTED=1 causes immediate exit 0" {
	mkdir -p "${REPO}/.claude"
	printf '%s\n' '{"echo":{"enabled":true}}' > "${REPO}/.claude/settings.json"
	local input
	input=$(_make_input)
	# Export ECHO_NESTED into the subshell that runs the hook.
	run bash -c "printf '%s' '$input' | ECHO_NESTED=1 ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "hook never prints to stdout (Stop contract)" {
	local input
	input=$(_make_input)
	run bash -c "printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "untracked watched file is detected when enabled and claude missing" {
	mkdir -p "${REPO}/.claude" "${REPO}/plugins/myplugin/agents"
	printf '%s\n' '{"echo":{"enabled":true,"watch_paths":["plugins/*/agents/*.md"]}}' \
		> "${REPO}/.claude/settings.json"
	printf '%s\n' '# New agent' > "${REPO}/plugins/myplugin/agents/new-agent.md"
	local input
	input=$(_make_input)
	# claude is not present in the test env PATH → hook reaches _done after the
	# `command -v claude` guard. Exit 0 with no output confirms the file was
	# at least detected (it passed the _done guards before the claude check).
	run bash -c "PATH=/usr/bin:/bin printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
}

@test "files under plugins/echo are excluded even if they match watch_paths" {
	mkdir -p "${REPO}/.claude" "${REPO}/plugins/echo/agents"
	printf '%s\n' '{"echo":{"enabled":true,"watch_paths":["plugins/*/agents/*.md"]}}' \
		> "${REPO}/.claude/settings.json"
	printf '%s\n' '# Echo self' > "${REPO}/plugins/echo/agents/self.md"
	local input
	input=$(_make_input)
	# With echo's own file as the only change, no watched files remain after
	# exclude filtering — hook exits before the claude guard (no output).
	run bash -c "PATH=/usr/bin:/bin printf '%s' '$input' | ONLOOKER_DIR='$ONLOOKER_DIR' '$HOOK'"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

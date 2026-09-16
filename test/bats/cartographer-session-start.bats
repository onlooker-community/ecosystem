#!/usr/bin/env bats
# Cartographer reporting that its undocumented_entity globs can never match
# (ecosystem-449.21).
#
# Nothing drove this hook before this file. Every test below pins last_audit_at
# to now, so the interval gate returns and no detached audit is spawned -- which
# is also the condition the check most needs to survive, since a throttled audit
# is exactly when a dead config would otherwise stay invisible.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/cartographer-session-start.sh"

	FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${FIXTURE_REPO}/.claude"
	git -C "$FIXTURE_REPO" init -q
	git -C "$FIXTURE_REPO" config user.email test@example.com
	git -C "$FIXTURE_REPO" config user.name test
	git -C "$FIXTURE_REPO" remote add origin git@github.com:org/fixture.git
	printf '# Root\n' >"${FIXTURE_REPO}/CLAUDE.md"
	git -C "$FIXTURE_REPO" add -A
	git -C "$FIXTURE_REPO" commit -qm init

	source "${PLUGIN_ROOT}/scripts/lib/cartographer-project-key.sh"
	PROJECT_KEY=$(cartographer_project_key "$FIXTURE_REPO")
	mkdir -p "${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}"
	# Interval gate returns: no audit is ever spawned by these tests.
	date +%s >"${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}/last_audit_at"
}

_settings() {
	printf '%s\n' "$1" >"${FIXTURE_REPO}/.claude/settings.json"
}

_run_hook() {
	run bash -c "printf '%s' '$(jq -cn --arg cwd "$FIXTURE_REPO" \
		'{cwd: $cwd, session_id: "sess-carto", hook_event_name: "SessionStart", source: "startup"}')' | '$HOOK'"
}

@test "reports when undocumented_entity globs can never match" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	grep '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.plugin == "cartographer"
		         and .payload.config_key == "cartographer.undocumented_entity.globs"
		         and .payload.patterns == ["nowhere/*/"]' >/dev/null
}

# PLACEMENT CHECK. last_audit_at is pinned to now in setup, so the hook returns
# at the interval gate. The report must precede that return.
@test "reports even though the audit interval has not elapsed" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	[ "$status" -eq 0 ]
	grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "stays quiet when globs match real directories" {
	mkdir -p "${FIXTURE_REPO}/plugins/demo"
	_settings '{"cartographer":{"undocumented_entity":{"globs":["plugins/*/"]}}}'
	_run_hook
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

# The divergence from echo, exercised end to end: an untracked directory is a
# match for cartographer because its matcher expands against the filesystem.
@test "an untracked directory counts as a match" {
	mkdir -p "${FIXTURE_REPO}/untracked/child"
	printf 'untracked/\n' >"${FIXTURE_REPO}/.gitignore"
	_settings '{"cartographer":{"undocumented_entity":{"globs":["untracked/*/"]}}}'
	_run_hook
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "emits once across two sessions, not once per SessionStart" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	_run_hook
	count=$(grep -c '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG")
	[[ "$count" == "1" ]]
}

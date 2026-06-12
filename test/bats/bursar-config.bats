#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/bursar-config.sh"
}

@test "bursar is disabled by default" {
	bursar_config_load ""
	run bursar_config_enabled
	[ "$status" -ne 0 ]
}

@test "user-level settings.json can enable bursar" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"enabled":true}}' > "${HOME}/.claude/settings.json"
	bursar_config_load ""
	run bursar_config_enabled
	[ "$status" -eq 0 ]
}

@test "repo-level settings.json overrides user-level" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"enabled":true}}' > "${HOME}/.claude/settings.json"
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"bursar":{"enabled":false}}' > "${repo}/.claude/settings.json"
	bursar_config_load "$repo"
	run bursar_config_enabled
	[ "$status" -ne 0 ]
}

@test "default window is rolling_7d" {
	bursar_config_load ""
	[ "$(bursar_config_window)" = "rolling_7d" ]
}

@test "window can be set to calendar_week" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"window":"calendar_week"}}' > "${HOME}/.claude/settings.json"
	bursar_config_load ""
	[ "$(bursar_config_window)" = "calendar_week" ]
}

@test "an invalid window falls back to rolling_7d" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"window":"yearly"}}' > "${HOME}/.claude/settings.json"
	bursar_config_load ""
	[ "$(bursar_config_window)" = "rolling_7d" ]
}

@test "default week_start is monday" {
	bursar_config_load ""
	[ "$(bursar_config_week_start)" = "monday" ]
}

@test "week_start can be set to sunday" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"week_start":"sunday"}}' > "${HOME}/.claude/settings.json"
	bursar_config_load ""
	[ "$(bursar_config_week_start)" = "sunday" ]
}

@test "surfacing is on by default and can be disabled" {
	bursar_config_load ""
	run bursar_config_surface_enabled
	[ "$status" -eq 0 ]

	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"surface_at_session_start":false}}' > "${HOME}/.claude/settings.json"
	bursar_config_load ""
	run bursar_config_surface_enabled
	[ "$status" -ne 0 ]
}

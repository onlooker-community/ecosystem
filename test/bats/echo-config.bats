#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/echo-config.sh"
}

@test "echo is disabled by default" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	run echo_config_enabled
	[ "$status" -ne 0 ]
}

@test "settings.json echo.enabled=true enables echo" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"echo":{"enabled":true}}' > "${repo}/.claude/settings.json"
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$repo"
	run echo_config_enabled
	[ "$status" -eq 0 ]
}

@test "settings.json echo.enabled=false overrides plugin default" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"echo":{"enabled":false}}' > "${repo}/.claude/settings.json"
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$repo"
	run echo_config_enabled
	[ "$status" -ne 0 ]
}

@test "default model is claude-haiku-4-5-20251001" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local m
	m=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_model)
	[ "$m" = "claude-haiku-4-5-20251001" ]
}

@test "default timeout is 60" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local t
	t=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_timeout)
	[ "$t" = "60" ]
}

@test "default drift_threshold is 0.05" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local d
	d=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_drift_threshold)
	[ "$d" = "0.05" ]
}

@test "default watch_paths includes plugins/*/agents/*.md" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local paths
	paths=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_watch_paths)
	printf '%s\n' "$paths" | grep -q 'plugins/\*/agents/\*.md'
}

@test "exclude_paths always includes plugins/echo/** regardless of config" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local excl
	excl=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_exclude_paths)
	printf '%s\n' "$excl" | grep -q 'plugins/echo/\*\*'
}

@test "settings.json model override wins over plugin default" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"echo":{"evaluation":{"model":"claude-opus-4-7"}}}' > "${repo}/.claude/settings.json"
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$repo"
	local m
	m=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_model)
	[ "$m" = "claude-opus-4-7" ]
}

@test "settings.json drift_threshold override wins" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"echo":{"drift_threshold":0.1}}' > "${repo}/.claude/settings.json"
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$repo"
	local d
	d=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_drift_threshold)
	[ "$d" = "0.1" ]
}

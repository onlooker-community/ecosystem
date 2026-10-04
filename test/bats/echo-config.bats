#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/echo-config.sh"
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

# Each accessor carries its own hardcoded fallback for a missing config. When
# one disagrees with config.json, a plugin with no config resolves a different
# value than one with it. It matters more here than it looks: both measurement
# runners stamp the model into every artifact they write, so a drifted fallback
# silently mislabels the run it is supposed to make reproducible (ADR-004).
#
# This replaces the same guard on drift_threshold, which went with the stop
# gate in ONL-103.
@test "the shipped defaults match the accessor fallbacks" {
	local shipped_model shipped_timeout lib
	lib="${PLUGIN_ROOT}/scripts/lib/echo-config.sh"
	shipped_model=$(jq -r '.echo.evaluation.model' "${PLUGIN_ROOT}/config.json")
	shipped_timeout=$(jq -r '.echo.evaluation.timeout_seconds' "${PLUGIN_ROOT}/config.json")
	grep -q "val:-${shipped_model}}" "$lib"
	grep -q "val:-${shipped_timeout}}" "$lib"
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

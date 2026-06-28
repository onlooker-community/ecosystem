#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-config.sh"
}

@test "stop_hook defaults to disabled" {
	tribunal_config_load ""
	run tribunal_config_stop_hook_enabled
	[ "$status" -ne 0 ]
}

@test "default judge_types is standard + adversarial" {
	tribunal_config_load ""
	local types
	types=$(tribunal_config_get_json '.tribunal.session.judge_types')
	[ "$types" = '["standard","adversarial"]' ]
}

@test "default gate_policy is majority" {
	tribunal_config_load ""
	local v
	v=$(tribunal_config_get '.tribunal.session.gate_policy')
	[ "$v" = "majority" ]
}

@test "judge model falls back to tribunal.judges.model when no per-type override" {
	tribunal_config_load ""
	local m
	m=$(tribunal_config_judge_model "standard")
	[ "$m" = "claude-opus-4-7" ]
}

@test "per-judge-type model override wins over fallback" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"tribunal":{"judges":{"security":{"model":"claude-opus-4-7-deep"}}}}' > "${HOME}/.claude/settings.json"
	tribunal_config_load ""
	local m
	m=$(tribunal_config_judge_model "security")
	[ "$m" = "claude-opus-4-7-deep" ]
	# Other types still fall through to the default.
	m=$(tribunal_config_judge_model "standard")
	[ "$m" = "claude-opus-4-7" ]
}

@test "deep-merge preserves unset defaults" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"tribunal":{"session":{"max_iterations":7}}}' > "${HOME}/.claude/settings.json"
	tribunal_config_load ""
	local mi gp
	mi=$(tribunal_config_get '.tribunal.session.max_iterations')
	gp=$(tribunal_config_get '.tribunal.session.gate_policy')
	[ "$mi" = "7" ]
	[ "$gp" = "majority" ]
}

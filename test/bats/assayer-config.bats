#!/usr/bin/env bats

# Exercises Assayer config loading: defaults and per-project overrides.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-config.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${REPO}/.claude"
}

@test "disabled by default (no settings)" {
	assayer_config_load "$REPO"
	run assayer_config_enabled
	[ "$status" -ne 0 ]
}

@test "enabled when settings opt in" {
	printf '%s\n' '{"assayer":{"enabled":true}}' >"${REPO}/.claude/settings.json"
	assayer_config_load "$REPO"
	run assayer_config_enabled
	[ "$status" -eq 0 ]
}

@test "default model is haiku" {
	assayer_config_load "$REPO"
	[ "$(assayer_config_model)" = "claude-haiku-4-5-20251001" ]
}

@test "model override is honored" {
	printf '%s\n' '{"assayer":{"evaluation":{"model":"claude-opus-4-8"}}}' >"${REPO}/.claude/settings.json"
	assayer_config_load "$REPO"
	[ "$(assayer_config_model)" = "claude-opus-4-8" ]
}

@test "default max_claims is 12" {
	assayer_config_load "$REPO"
	[ "$(assayer_config_max_claims)" = "12" ]
}

@test "default min_confidence is 0.5" {
	assayer_config_load "$REPO"
	[ "$(assayer_config_min_confidence)" = "0.5" ]
}

@test "min_confidence override is honored" {
	printf '%s\n' '{"assayer":{"min_confidence":0.8}}' >"${REPO}/.claude/settings.json"
	assayer_config_load "$REPO"
	[ "$(assayer_config_min_confidence)" = "0.8" ]
}

@test "default timeout is 60" {
	assayer_config_load "$REPO"
	[ "$(assayer_config_timeout)" = "60" ]
}

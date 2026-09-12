#!/usr/bin/env bats
# Config resolution for the plugin-currency surfacer (ecosystem-449.59).

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# The substrate IS the plugin root, so config.json at the repo root is the
	# defaults layer config_load_plugin reads.
	export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"

	source "${REPO_ROOT}/scripts/lib/plugin-currency-config.sh"
}

@test "ships the documented defaults" {
	plugin_currency_config_load "$PROJECT_REPO"
	[ "$(plugin_currency_config_get '.plugin_currency.enabled')" = "true" ]
	[ "$(plugin_currency_config_get '.plugin_currency.probe_ttl_hours')" = "6" ]
	[ "$(plugin_currency_config_get '.plugin_currency.wall_clock_budget_ms')" = "1500" ]
	[ "$(plugin_currency_config_get '.plugin_currency.probe_timeout_seconds')" = "30" ]
	[ "$(plugin_currency_config_get '.plugin_currency.surface_when_current')" = "false" ]
	[ "$(plugin_currency_config_get_json '.plugin_currency.marketplaces')" = '["onlooker-community"]' ]
}

@test "a project setting overrides the shipped default" {
	mkdir -p "${PROJECT_REPO}/.claude"
	jq -n '{plugin_currency: {probe_ttl_hours: 1}}' \
		>"${PROJECT_REPO}/.claude/settings.json"

	plugin_currency_config_load "$PROJECT_REPO"
	[ "$(plugin_currency_config_get '.plugin_currency.probe_ttl_hours')" = "1" ]
	# The untouched siblings must survive the merge.
	[ "$(plugin_currency_config_get '.plugin_currency.enabled')" = "true" ]
}

@test "a user setting overrides the shipped default and loses to the project" {
	mkdir -p "$CLAUDE_HOME" "${PROJECT_REPO}/.claude"
	jq -n '{plugin_currency: {probe_ttl_hours: 2, surface_when_current: true}}' \
		>"${CLAUDE_HOME}/settings.json"
	jq -n '{plugin_currency: {probe_ttl_hours: 1}}' \
		>"${PROJECT_REPO}/.claude/settings.json"

	plugin_currency_config_load "$PROJECT_REPO"
	[ "$(plugin_currency_config_get '.plugin_currency.probe_ttl_hours')" = "1" ]
	[ "$(plugin_currency_config_get '.plugin_currency.surface_when_current')" = "true" ]
}

@test "enabled false reads back as false, not as empty" {
	# Regression guard for the jq `//` trap documented in config_get: a boolean
	# false must not degrade to "" and silently flip a true default.
	mkdir -p "${PROJECT_REPO}/.claude"
	jq -n '{plugin_currency: {enabled: false}}' \
		>"${PROJECT_REPO}/.claude/settings.json"

	plugin_currency_config_load "$PROJECT_REPO"
	[ "$(plugin_currency_config_get '.plugin_currency.enabled')" = "false" ]
}

@test "loading without a repo root still yields the shipped defaults" {
	plugin_currency_config_load ""
	[ "$(plugin_currency_config_get '.plugin_currency.probe_ttl_hours')" = "6" ]
}

#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/governor"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/governor-config.sh"
}

@test "default enforcement is soft" {
	governor_config_load ""
	local v
	v=$(governor_config_enforcement)
	[ "$v" = "soft" ]
}

@test "enforcement can be overridden to hard" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"governor":{"enforcement":"hard"}}' > "${HOME}/.claude/settings.json"
	governor_config_load ""
	local v
	v=$(governor_config_enforcement)
	[ "$v" = "hard" ]
}

@test "default tokens budget is 100000" {
	governor_config_load ""
	local v
	v=$(governor_config_get '.governor.session.tokens_default')
	[ "$v" = "100000" ]
}

@test "default cost budget is 1.0" {
	governor_config_load ""
	local v
	v=$(governor_config_get '.governor.session.cost_usd_default')
	[ "$v" = "1.0" ]
}

@test "default safety margin is 1.3" {
	governor_config_load ""
	local v
	v=$(governor_config_get '.governor.estimation.safety_margin')
	[ "$v" = "1.3" ]
}

@test "default hard_stop_margin is 1.5" {
	governor_config_load ""
	local v
	v=$(governor_config_get '.governor.estimation.hard_stop_margin')
	[ "$v" = "1.5" ]
}

@test "default estimation method is tier_table" {
	governor_config_load ""
	local v
	v=$(governor_config_get '.governor.estimation.method')
	[ "$v" = "tier_table" ]
}

@test "governor_config_get returns empty for missing key" {
	governor_config_load ""
	local v
	v=$(governor_config_get '.governor.no_such_key')
	[ -z "$v" ]
}


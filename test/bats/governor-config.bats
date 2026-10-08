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


# ----------------------------------------------------------------------------
# ONL-132 / ecosystem-ac8r8d.3. tokens_default used the ${v:-100000} idiom,
# which substitutes only on an EMPTY value. TOKENS_BUDGET reaches arithmetic
# three times in governor-pre-tool-use.sh -- :141, :146, :180 -- where a bare
# word is read as a variable name and set -u kills the hook at status 0.
#
# Fixture is "unlimited", not "100000tok": digit-leading hits the milder mode
# where the comparison merely returns non-zero and the hook survives with the
# budget silently not bounding anything. That mode is covered at the accessor
# in config-get-int.bats.
#
# SCOPE: the two tests below exercise governor_config_int directly, so against
# unmigrated code they fail only because the function does not exist. They guard
# the wiring -- governor populates `_GOVERNOR_CONFIG` (uppercase), unlike
# counsel/scribe/warden, and a wrapper on the wrong spelling would silently
# return the default for everything. "a valid tokens_default override still
# wins" is the assertion that catches that; the "falls back" one does not,
# because an unset variable also yields the default.
#
# The ABORT itself is covered where it is actually reachable: the env-var route
# in gate-block-contract.bats, which drives the hook and asserts on
# governor.gate.checked. That file is also where the valid env override is
# already exercised (ONLOOKER_SESSION_BUDGET_TOKENS=1).
# ----------------------------------------------------------------------------

@test "a non-numeric tokens_default falls back to the shipped default" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"governor":{"session":{"tokens_default":"unlimited"}}}' > "${HOME}/.claude/settings.json"
	governor_config_load ""
	[ "$(governor_config_int '.governor.session.tokens_default' 100000)" = "100000" ]
}

# A bad budget must not be read as "no budget": falling back to 0 would make
# every projection exceed it, and falling back to unbounded would ungovern the
# session. The shipped default is the only safe landing.
@test "a valid tokens_default override still wins" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"governor":{"session":{"tokens_default":250000}}}' > "${HOME}/.claude/settings.json"
	governor_config_load ""
	[ "$(governor_config_int '.governor.session.tokens_default' 100000)" = "250000" ]
}

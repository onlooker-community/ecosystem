#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/warden"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/warden-config.sh"
}

@test "defaults are preserved when an overlay sets only some keys" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"warden":{"enabled":true,"escalation":{"enabled":false}}}' > "${HOME}/.claude/settings.json"
	warden_config_load ""
	# escalation.enabled overridden to false…
	[ "$(warden_config_get '.warden.escalation.enabled')" = "false" ]
	# …but shipped defaults survive the deep merge.
	[ "$(warden_config_get '.warden.detection.close_threshold')" = "0.65" ]
	[ "$(warden_config_get '.warden.scan.max_content_chars')" = "20000" ]
}

@test "config_get_json returns arrays" {
	warden_config_load ""
	run warden_config_get_json '.warden.scan.sources'
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -e 'index("web_fetch") != null and index("file_read") != null' >/dev/null
}

# ----------------------------------------------------------------------------
# ONL-132 / ecosystem-ac8r8d.3. escalation.n and escalation.min_valid_samples
# used the ${v:-N} idiom (empty-only). Both reach arithmetic in
# warden-evaluator.sh: n_samples drives `for (( i=0; i<n_samples; i++ ))` at
# :165 and :188, and min_valid is compared with [[ "$valid_count" -lt
# "$min_valid" ]] at :212. [[ -lt ]] evaluates its operands arithmetically, so
# it dies the same way (( )) does -- note the single-bracket [ -lt ] does NOT,
# it reports "integer expression expected" and execution continues.
#
# n_samples is the more dangerous of the two: a non-numeric value kills the
# shell at the top of the sampling loop, so warden escalates nothing while
# reporting no error.
#
# Fixtures use "unlimited" rather than a digit-leading value, which would hit
# the milder surviving mode and pass against unfixed code.
#
# Neither is a float knob -- temperature is, and is deliberately NOT migrated,
# since config_get_int refuses floats by contract.
#
# SCOPE, stated plainly so these are not mistaken for abort coverage. They
# exercise warden_config_int directly, so against unmigrated code they fail only
# because the function does not exist -- a tautology, not evidence. Driving the
# real abort would mean standing up the escalation path with a stubbed model,
# which belongs with the evaluator tests, not here.
#
# What they DO guard is the config-var wiring, and that is a live risk: warden
# populates `_warden_CONFIG` (lowercase), while cartographer and governor use the
# uppercase spelling. A wrapper pointed at the wrong one reads an unset variable
# and silently returns the default for every value, ignoring config completely.
# Verified by mutation -- renaming the var to _WARDEN_CONFIG is caught by
# "valid escalation sample counts still win" and by NOTHING else here: both
# "falls back" assertions pass under it, because reading an unset variable also
# yields the default. That test is the load-bearing one.
# ----------------------------------------------------------------------------

@test "a non-numeric escalation.n falls back to the shipped default" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"warden":{"escalation":{"n":"unlimited"}}}' > "${HOME}/.claude/settings.json"
	warden_config_load ""
	[ "$(warden_config_int '.warden.escalation.n' 3)" = "3" ]
}

@test "a non-numeric escalation.min_valid_samples falls back to the shipped default" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"warden":{"escalation":{"min_valid_samples":"unlimited"}}}' > "${HOME}/.claude/settings.json"
	warden_config_load ""
	[ "$(warden_config_int '.warden.escalation.min_valid_samples' 2)" = "2" ]
}

@test "valid escalation sample counts still win" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"warden":{"escalation":{"n":5,"min_valid_samples":4}}}' > "${HOME}/.claude/settings.json"
	warden_config_load ""
	[ "$(warden_config_int '.warden.escalation.n' 3)" = "5" ] || return 1
	[ "$(warden_config_int '.warden.escalation.min_valid_samples' 2)" = "4" ]
}

# temperature is a float and must stay on the string accessor. Pinning it here
# so a future sweep-driven migration does not quietly round it to an integer.
@test "escalation.temperature is not an int knob and keeps its float value" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"warden":{"escalation":{"temperature":0.7}}}' > "${HOME}/.claude/settings.json"
	warden_config_load ""
	[ "$(warden_config_get '.warden.escalation.temperature')" = "0.7" ]
}

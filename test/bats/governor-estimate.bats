#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/governor"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/governor-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/governor-estimate.sh"

	governor_config_load ""
}

@test "governor_estimate_method returns tier_table" {
	local m
	m=$(governor_estimate_method)
	[ "$m" = "tier_table" ]
}

@test "empty input returns a nonzero estimate" {
	local t
	t=$(governor_estimate_tokens "")
	[ "$t" -gt 0 ]
}

@test "prose input produces a positive estimate" {
	local input="This is a plain English sentence with no special characters at all."
	local t
	t=$(governor_estimate_tokens "$input" 1.0)
	[ "$t" -gt 0 ]
}

@test "JSON input produces higher token density estimate than prose" {
	local prose="This is a longer plain English paragraph used as baseline comparison text."
	local json='{"key":"value","nested":{"array":[1,2,3,4,5],"flag":true},"extra":"padding"}'

	local chars_prose=${#prose}
	local chars_json=${#json}
	local toks_prose
	local toks_json
	toks_prose=$(governor_estimate_tokens "$prose" 1.0)
	toks_json=$(governor_estimate_tokens "$json" 1.0)

	# JSON uses 3 chars/tok vs 4 for prose, so per char JSON should yield more tokens.
	local ratio_prose=$(( toks_prose * 100 / chars_prose ))
	local ratio_json=$(( toks_json * 100 / chars_json ))
	[ "$ratio_json" -ge "$ratio_prose" ]
}

@test "safety margin multiplies the base estimate" {
	local input="hello world this is a test sentence"
	local base
	local with_margin
	base=$(governor_estimate_tokens "$input" 1.0)
	with_margin=$(governor_estimate_tokens "$input" 1.3)

	# with_margin should be >= base (margin >= 1.0)
	[ "$with_margin" -ge "$base" ]
}

@test "estimate scales with input length" {
	local short="short"
	local long
	long=$(printf 'x%.0s' {1..500})
	local t_short t_long
	t_short=$(governor_estimate_tokens "$short" 1.0)
	t_long=$(governor_estimate_tokens "$long" 1.0)
	[ "$t_long" -gt "$t_short" ]
}

@test "governor_estimate_cost returns a positive float for nonzero tokens" {
	local cost
	cost=$(governor_estimate_cost 10000)
	# Should be > 0
	awk "BEGIN { exit ($cost > 0) ? 0 : 1 }"
}

@test "governor_estimate_cost returns 0-ish for 0 tokens" {
	local cost
	cost=$(governor_estimate_cost 0)
	[ "$cost" = "0.000000" ] || [ "$cost" = "0" ] || [ "$cost" = "0.0" ]
}

#!/usr/bin/env bats

# Exercises claim parsing: assayer_parse_claims and the extraction prompt.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-extract.sh"
}

@test "parses a clean JSON array of claims" {
	run assayer_parse_claims '[{"text":"tests pass","type":"tests_pass","command_keyword":"test","confidence":0.9}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].type')" = "tests_pass" ]
}

@test "strips markdown fences" {
	local raw
	raw=$'```json\n[{"text":"build ok","type":"build_succeeds","command_keyword":"build","confidence":0.8}]\n```'
	run assayer_parse_claims "$raw"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
}

@test "drops malformed entries and entries without text" {
	run assayer_parse_claims '[{"text":"ok","type":"generic","confidence":0.7},{"no_text":true},{"text":""}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
}

@test "coerces unknown type to generic" {
	run assayer_parse_claims '[{"text":"thing","type":"made_up","command_keyword":"x","confidence":0.7}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].type')" = "generic" ]
}

@test "defaults confidence when missing or non-numeric" {
	run assayer_parse_claims '[{"text":"thing","type":"generic","command_keyword":"x"}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].confidence')" = "0.6" ]
}

@test "lowercases command_keyword" {
	run assayer_parse_claims '[{"text":"thing","type":"generic","command_keyword":"TEST","confidence":0.7}]'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].command_keyword')" = "test" ]
}

@test "non-array input yields empty array" {
	run assayer_parse_claims '{"text":"not an array"}'
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
}

@test "garbage input yields empty array" {
	run assayer_parse_claims 'I could not find any claims.'
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
}

@test "empty input yields empty array" {
	run assayer_parse_claims ""
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
}

@test "extraction prompt includes the message and the JSON contract" {
	run assayer_build_extraction_prompt "I ran the tests and they pass." 5
	[ "$status" -eq 0 ]
	[[ "$output" == *"I ran the tests and they pass."* ]]
	[[ "$output" == *"TESTABLE SUCCESS CLAIM"* ]]
	[[ "$output" == *"at most 5 claims"* ]]
}

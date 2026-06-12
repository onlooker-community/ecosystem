#!/usr/bin/env bats

# Secret-shaped strings are assembled at runtime (prefix + filler) so this test
# file itself contains no literal secret token a scanner would flag.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-redact.sh"
}

@test "ordinary code passes through unchanged" {
	local out
	out=$(printf '%s' "x = 2  # bumped" | lineage_redact 4000 true)
	[ "$out" = "x = 2  # bumped" ]
}

@test "an Anthropic-style API key is redacted" {
	local tok out
	tok="sk-ant-$(printf 'a%.0s' $(seq 1 28))"
	out=$(printf '%s' "key=\"${tok}\"" | lineage_redact 4000 true)
	[[ "$out" == *"[REDACTED:secret]"* ]]
	[[ "$out" != *"$tok"* ]]
}

@test "a GitHub-style token is redacted" {
	local tok out
	tok="ghp_$(printf '0%.0s' $(seq 1 36))"
	out=$(printf '%s' "$tok" | lineage_redact 4000 true)
	[[ "$out" == *"[REDACTED:secret]"* ]]
	[[ "$out" != *"$tok"* ]]
}

@test "a KEY=value secret keeps the key but redacts the value" {
	local val out
	val=$(printf 'x%.0s' $(seq 1 24))
	out=$(printf '%s' "API_TOKEN=${val}" | lineage_redact 4000 true)
	[[ "$out" == *"API_TOKEN="* ]]
	[[ "$out" == *"[REDACTED:secret]"* ]]
	[[ "$out" != *"$val"* ]]
}

@test "redaction is skipped when disabled" {
	local tok out
	tok="ghp_$(printf '0%.0s' $(seq 1 36))"
	out=$(printf '%s' "$tok" | lineage_redact 4000 false)
	[ "$out" = "$tok" ]
}

@test "content longer than the cap is truncated with a marker" {
	local out
	out=$(printf '%s' "abcdefghij" | lineage_redact 4 true)
	[[ "$out" == "abcd"* ]]
	[[ "$out" == *"truncated 6 chars"* ]]
}

@test "content within the cap is not truncated" {
	local out
	out=$(printf '%s' "abcd" | lineage_redact 4 true)
	[ "$out" = "abcd" ]
}

#!/usr/bin/env bats

# The kind x host decision (customs spec, section 3) and its config.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}/plugins/customs"
	source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/customs-config.sh"
	source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/customs-allowlist.sh"
}

_decide() {
	local user="${3:-}" record="${4:-}"
	[[ -z "$user" ]] && user='{}'
	[[ -z "$record" ]] && record='["bearer_token"]'
	customs_decide "$1" "$2" "$user" "$record"
}

@test "a token to its issuer is allowed" {
	[ "$(_decide '["github_token"]' '["api.github.com"]')" = "allow" ]
	[ "$(_decide '["anthropic_key"]' '["api.anthropic.com"]')" = "allow" ]
}

@test "a token to anywhere else is flagged, including another issuer" {
	[ "$(_decide '["github_token"]' '["paste.example.com"]')" = "flag" ]
	[ "$(_decide '["github_token"]' '["api.anthropic.com"]')" = "flag" ]
}

@test "every host must be allowed, not just one" {
	[ "$(_decide '["github_token"]' '["api.github.com","paste.example.com"]')" = "flag" ]
}

@test "no readable host is flagged" {
	[ "$(_decide '["github_token"]' '[]')" = "flag" ]
}

@test "a wildcard matches its subdomains and the bare domain, and nothing else" {
	[ "$(_decide '["aws_access_key_id"]' '["s3.us-east-1.amazonaws.com"]')" = "allow" ]
	[ "$(_decide '["aws_access_key_id"]' '["amazonaws.com"]')" = "allow" ]
	[ "$(_decide '["aws_access_key_id"]' '["notamazonaws.com"]')" = "flag" ]
}

@test "user pairs add to the built-in hosts instead of replacing them" {
	local user='{"github_token":["ghe.example.com"]}'
	[ "$(_decide '["github_token"]' '["ghe.example.com"]' "$user")" = "allow" ]
	[ "$(_decide '["github_token"]' '["api.github.com"]' "$user")" = "allow" ]
}

@test "a record-only kind alone is recorded, wherever it goes" {
	[ "$(_decide '["bearer_token"]' '["paste.example.com"]')" = "record" ]
}

@test "a gated kind still decides when a record-only kind rides along" {
	[ "$(_decide '["github_token","bearer_token"]' '["paste.example.com"]')" = "flag" ]
	[ "$(_decide '["github_token","bearer_token"]' '["api.github.com"]')" = "record" ]
}

@test "malformed config is treated as empty, not as a crash" {
	[ "$(customs_decide '["github_token"]' '["api.github.com"]' 'null' 'null')" = "allow" ]
	[ "$(customs_decide '["github_token"]' '["api.github.com"]' '["x"]' '"x"')" = "allow" ]
}

@test "malformed kinds or hosts print nothing and fail, never allow" {
	bats_require_minimum_version 1.5.0
	# jq's error goes to stderr; the decision on stdout must stay empty.
	run --separate-stderr customs_decide 'null' '["api.github.com"]' '{}' '[]'
	[ "$status" -ne 0 ]
	[ -z "$output" ]
	run --separate-stderr customs_decide '["github_token"]' '"api.github.com"' '{}' '[]'
	[ "$status" -ne 0 ]
	[ -z "$output" ]
}

@test "the reason names kind and host" {
	run customs_reason '["github_token"]' '["paste.example.com"]'
	[[ "$output" == *"a GitHub token"* ]] || false
	[[ "$output" == *"paste.example.com"* ]] || false
	[[ "$output" == *"customs.pairs"* ]] || false
}

@test "the reason says so when no host could be read" {
	run customs_reason '["openai_key"]' '[]'
	[[ "$output" == *"a host customs could not read"* ]] || false
}

@test "config defaults ship ask, no user pairs, bearer record-only" {
	customs_config_load "$HOME"
	[ "$(customs_config_get '.customs.mode')" = "ask" ]
	[ "$(customs_config_get_json '.customs.pairs' | jq -c .)" = '{}' ]
	[ "$(customs_config_get_json '.customs.record_only_kinds' | jq -c .)" = '["bearer_token"]' ]
}

@test "settings override mode and add pairs" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"customs":{"mode":"deny","pairs":{"openai_key":["llm.example.com"]}}}' > "${HOME}/.claude/settings.json"
	customs_config_load "$HOME"
	[ "$(customs_config_get '.customs.mode')" = "deny" ]
	[ "$(customs_config_get_json '.customs.pairs.openai_key' | jq -c .)" = '["llm.example.com"]' ]
}

#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-config.sh"
}

@test "default max_snippet_chars is 4000" {
	lineage_config_load ""
	[ "$(lineage_config_max_snippet_chars)" = "4000" ]
}

@test "max_snippet_chars is configurable" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"lineage":{"max_snippet_chars":256}}' > "${HOME}/.claude/settings.json"
	lineage_config_load ""
	[ "$(lineage_config_max_snippet_chars)" = "256" ]
}

@test "redaction is on by default and can be disabled with an explicit false" {
	lineage_config_load ""
	run lineage_config_redact_enabled
	[ "$status" -eq 0 ]

	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"lineage":{"redact_secrets":false}}' > "${HOME}/.claude/settings.json"
	lineage_config_load ""
	run lineage_config_redact_enabled
	[ "$status" -ne 0 ]
}

@test "default prompt_source is historian_then_transcript" {
	lineage_config_load ""
	[ "$(lineage_config_prompt_source)" = "historian_then_transcript" ]
}

@test "ignore_globs are exposed one per line" {
	lineage_config_load ""
	run lineage_config_ignore_globs
	[ "$status" -eq 0 ]
	[[ "$output" == *"node_modules"* ]]
	[[ "$output" == *".lock"* ]]
}

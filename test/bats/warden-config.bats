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

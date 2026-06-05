#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/compass"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-config.sh"
}

@test "compass is disabled by default" {
	compass_config_load ""
	run compass_config_enabled
	[ "$status" -ne 0 ]
}

@test "user-level settings.json can enable compass" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"compass":{"enabled":true}}' > "${HOME}/.claude/settings.json"
	compass_config_load ""
	run compass_config_enabled
	[ "$status" -eq 0 ]
}

@test "repo-level settings.json overrides user-level" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"compass":{"enabled":true}}' > "${HOME}/.claude/settings.json"
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"compass":{"enabled":false}}' > "${repo}/.claude/settings.json"
	compass_config_load "$repo"
	run compass_config_enabled
	[ "$status" -ne 0 ]
}

@test "shipped defaults survive a partial overlay" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' \
		'{"compass":{"enabled":true,"evaluator":{"n":7}}}' \
		> "${HOME}/.claude/settings.json"
	compass_config_load ""
	# Overlay key is picked up.
	[ "$(compass_config_get '.compass.evaluator.n')" = "7" ]
	# Defaults under the same parent key survive the deep merge.
	[ "$(compass_config_get '.compass.evaluator.temperature')" = "0.3" ]
	[ "$(compass_config_get '.compass.confidence_threshold')" = "0.65" ]
	[ "$(compass_config_get '.compass.stddev_threshold')" = "0.2" ]
}

@test "config_get_json returns skip_globs array" {
	compass_config_load ""
	run compass_config_get_json '.compass.skip_globs'
	[ "$status" -eq 0 ]
	printf '%s' "$output" \
		| jq -e 'index("**/*.lock") != null and index("**/.git/**") != null' >/dev/null
}

@test "transcript block no longer carries the obsolete transcript_max_age_seconds knob" {
	compass_config_load ""
	# Future readers should not find the removed knob — see ADR-001 (read by
	# transcript_path from hook JSON, no event-log fallback).
	[ -z "$(compass_config_get '.compass.transcript.transcript_max_age_seconds')" ]
}

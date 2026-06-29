#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/compass"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-config.sh"
}

@test "shipped defaults survive a partial overlay" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' \
		'{"compass":{"evaluator":{"n":7}}}' \
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

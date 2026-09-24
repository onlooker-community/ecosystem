#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/echo-config.sh"
}

@test "default model is claude-haiku-4-5-20251001" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local m
	m=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_model)
	[ "$m" = "claude-haiku-4-5-20251001" ]
}

@test "default timeout is 60" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local t
	t=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_timeout)
	[ "$t" = "60" ]
}

# 0.28 is the measured p95 of |delta| between two independent judge
# evaluations of IDENTICAL content, pooled across the file kinds watch_paths
# actually covers (ONL-102, 86 judge calls over six files, haiku-4-5). The old
# 0.05 sat far below the judge's own noise, so echo reported sampling error as
# improvements and regressions. See
# plugins/echo/docs/adr/004-drift-threshold-from-measured-spread.md.
@test "default drift_threshold is the measured 0.28" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local d
	d=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_drift_threshold)
	[ "$d" = "0.28" ]
}

@test "the drift_threshold fallback matches the shipped default" {
	# The accessor carries its own hardcoded fallback for a missing config.
	# When it disagrees with config.json, a plugin with no config silently
	# scores against a different threshold than one with it.
	local shipped fallback
	shipped=$(jq -r '.echo.drift_threshold' "${PLUGIN_ROOT}/config.json")
	fallback=$(grep -o 'val:-[0-9.]*' "${PLUGIN_ROOT}/scripts/lib/echo-config.sh" \
		| grep -o '[0-9]\+\.[0-9]\+' | head -1)
	[ "$shipped" = "$fallback" ]
}

@test "default watch_paths includes plugins/*/agents/*.md" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local paths
	paths=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_watch_paths)
	printf '%s\n' "$paths" | grep -q 'plugins/\*/agents/\*.md'
}

@test "exclude_paths always includes plugins/echo/** regardless of config" {
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load ""
	local excl
	excl=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_exclude_paths)
	printf '%s\n' "$excl" | grep -q 'plugins/echo/\*\*'
}

@test "settings.json model override wins over plugin default" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"echo":{"evaluation":{"model":"claude-opus-4-7"}}}' > "${repo}/.claude/settings.json"
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$repo"
	local m
	m=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_model)
	[ "$m" = "claude-opus-4-7" ]
}

@test "settings.json drift_threshold override wins" {
	local repo="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${repo}/.claude"
	printf '%s\n' '{"echo":{"drift_threshold":0.1}}' > "${repo}/.claude/settings.json"
	CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_load "$repo"
	local d
	d=$(CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" echo_config_drift_threshold)
	[ "$d" = "0.1" ]
}

#!/usr/bin/env bats

# Exercises Inspector config loading: defaults, overrides, and the
# per-extension checks lookup helper.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/inspector"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/inspector-config.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${REPO}/.claude"
}

@test "default timeout_seconds_per_check is 10" {
	inspector_config_load "$REPO"
	[ "$(inspector_config_timeout_per_check)" = "10" ]
}

@test "timeout_seconds_per_check override is honored" {
	printf '%s\n' '{"inspector":{"timeout_seconds_per_check":3}}' >"${REPO}/.claude/settings.json"
	inspector_config_load "$REPO"
	[ "$(inspector_config_timeout_per_check)" = "3" ]
}

@test "default total_timeout_seconds is 30" {
	inspector_config_load "$REPO"
	[ "$(inspector_config_total_timeout)" = "30" ]
}

@test "default output_excerpt_max_bytes is 4096" {
	inspector_config_load "$REPO"
	[ "$(inspector_config_output_excerpt_max_bytes)" = "4096" ]
}

@test "show_clean_runs is false by default" {
	inspector_config_load "$REPO"
	run inspector_config_show_clean_runs
	[ "$status" -ne 0 ]
}

@test "show_clean_runs flips on when set" {
	printf '%s\n' '{"inspector":{"show_clean_runs":true}}' >"${REPO}/.claude/settings.json"
	inspector_config_load "$REPO"
	run inspector_config_show_clean_runs
	[ "$status" -eq 0 ]
}

@test "default exclude_paths includes node_modules and dist" {
	inspector_config_load "$REPO"
	local excludes
	excludes=$(inspector_config_exclude_paths)
	echo "$excludes" | jq -e 'index("node_modules")' >/dev/null
	echo "$excludes" | jq -e 'index("dist")' >/dev/null
}

@test "exclude_paths is fully replaced by repo settings (not merged)" {
	printf '%s\n' '{"inspector":{"exclude_paths":["only-this"]}}' >"${REPO}/.claude/settings.json"
	inspector_config_load "$REPO"
	local excludes
	excludes=$(inspector_config_exclude_paths)
	[ "$(echo "$excludes" | jq 'length')" = "1" ]
	echo "$excludes" | jq -e 'index("only-this")' >/dev/null
}

@test "checks_for_extension returns [] when extension is unconfigured" {
	inspector_config_load "$REPO"
	[ "$(inspector_config_checks_for_extension '.ts')" = "[]" ]
}

@test "checks_for_extension returns the configured object form" {
	cat >"${REPO}/.claude/settings.json" <<'EOF'
{ "inspector": { "checks": { ".ts": [
  { "name": "biome", "kind": "lint", "argv": ["biome", "check", "${file}"] }
] } } }
EOF
	inspector_config_load "$REPO"
	local checks
	checks=$(inspector_config_checks_for_extension '.ts')
	[ "$(echo "$checks" | jq 'length')" = "1" ]
	[ "$(echo "$checks" | jq -r '.[0].name')" = "biome" ]
	[ "$(echo "$checks" | jq -r '.[0].kind')" = "lint" ]
}

@test "checks_for_extension normalizes bare argv arrays into objects" {
	cat >"${REPO}/.claude/settings.json" <<'EOF'
{ "inspector": { "checks": { ".sh": [
  ["shellcheck", "${file}"]
] } } }
EOF
	inspector_config_load "$REPO"
	local checks
	checks=$(inspector_config_checks_for_extension '.sh')
	[ "$(echo "$checks" | jq -r '.[0].name')" = "shellcheck" ]
	[ "$(echo "$checks" | jq -r '.[0].kind')" = "lint" ]
	[ "$(echo "$checks" | jq -r '.[0].argv | length')" = "2" ]
}

@test "checks_for_extension returns [] for an empty extension" {
	inspector_config_load "$REPO"
	[ "$(inspector_config_checks_for_extension '')" = "[]" ]
}

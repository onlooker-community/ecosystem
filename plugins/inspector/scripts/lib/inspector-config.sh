#!/usr/bin/env bash
# inspector-config.sh — load and query Inspector configuration.
#
# Merges three layers in precedence order (later wins):
#   1. plugins/inspector/config.json    (plugin defaults)
#   2. ~/.claude/settings.json          (.inspector subtree)
#   3. <repo>/.claude/settings.json     (.inspector subtree)
#
# Usage:
#   inspector_config_load <repo_root>
#   inspector_config_get ".inspector.timeout_seconds_per_check"
#   inspector_config_get_json ".inspector.exclude_paths"
#   inspector_config_checks_for_extension ".ts"

_INSPECTOR_CONFIG=""
_INSPECTOR_PLUGIN_CONFIG=""

inspector_config_load() {
	local repo_root="${1:-}"
	local plugin_dir
	plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	local plugin_config="$plugin_dir/config.json"

	_INSPECTOR_PLUGIN_CONFIG="{}"
	if [[ -f "$plugin_config" ]]; then
		_INSPECTOR_PLUGIN_CONFIG=$(cat "$plugin_config")
	fi

	local home_settings="{}"
	if [[ -f "$HOME/.claude/settings.json" ]]; then
		home_settings=$(cat "$HOME/.claude/settings.json")
	fi

	local repo_settings="{}"
	if [[ -n "$repo_root" && -f "$repo_root/.claude/settings.json" ]]; then
		repo_settings=$(cat "$repo_root/.claude/settings.json")
	fi

	_INSPECTOR_CONFIG=$(jq -n \
		--argjson plugin "$_INSPECTOR_PLUGIN_CONFIG" \
		--argjson home "$home_settings" \
		--argjson repo "$repo_settings" \
		'$plugin * {"inspector": (($plugin.inspector // {}) * ($home.inspector // {}) * ($repo.inspector // {}))}')
}

inspector_config_get() {
	local path="${1:-}"
	printf '%s' "$_INSPECTOR_CONFIG" | jq -r "$path // empty" 2>/dev/null
}

inspector_config_get_json() {
	local path="${1:-}"
	printf '%s' "$_INSPECTOR_CONFIG" | jq -c "$path // empty" 2>/dev/null
}

inspector_config_show_clean_runs() {
	local v
	v=$(inspector_config_get '.inspector.show_clean_runs')
	[[ "$v" == "true" ]]
}

inspector_config_timeout_per_check() {
	local v
	v=$(inspector_config_get '.inspector.timeout_seconds_per_check')
	printf '%s' "${v:-10}"
}

inspector_config_total_timeout() {
	local v
	v=$(inspector_config_get '.inspector.total_timeout_seconds')
	printf '%s' "${v:-30}"
}

inspector_config_output_excerpt_max_bytes() {
	local v
	v=$(inspector_config_get '.inspector.output_excerpt_max_bytes')
	printf '%s' "${v:-4096}"
}

inspector_config_exclude_paths() {
	inspector_config_get_json '.inspector.exclude_paths // []'
}

# Emits a JSON array of {name, argv, kind} objects for the given file extension
# (including the leading dot). Returns an empty array when no checks are
# configured for the extension.
inspector_config_checks_for_extension() {
	local ext="${1:-}"
	[[ -z "$ext" ]] && { printf '[]'; return; }
	printf '%s' "$_INSPECTOR_CONFIG" | jq -c --arg ext "$ext" '
		(.inspector.checks // {}) as $checks
		| ($checks[$ext] // [])
		| map(
			if type == "array" then
				{ name: (.[0] // "check"), argv: ., kind: "lint" }
			else
				{ name: (.name // "check"), argv: (.argv // []), kind: (.kind // "lint") }
			end
		)
	' 2>/dev/null || printf '[]'
}

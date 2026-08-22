#!/usr/bin/env bash
# Config resolution for inspector.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/inspector/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   inspector_config_load <repo_root>    # populates _inspector_CONFIG (JSON)
#   inspector_config_get <jq-path>       # echoes string value (empty if unset)
#   inspector_config_get_json <jq-path>  # echoes JSON value (null if unset)

# Resolve the shared loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
_INSPECTOR_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/config-loader.sh
source "${_INSPECTOR_CONFIG_LIB_DIR}/../../../../scripts/lib/config-loader.sh"

_inspector_CONFIG="{}"

inspector_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "inspector" "$repo_root" "_inspector_CONFIG"
	return 0
}

inspector_config_get() {
	local path="$1"
	config_get "_inspector_CONFIG" "${path}"
}

inspector_config_get_json() {
	local path="$1"
	config_get_json "_inspector_CONFIG" "${path}"
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

inspector_config_show_clean_runs() {
	local v
	v=$(inspector_config_get '.inspector.show_clean_runs')
	[[ "$v" == "true" ]]
}

inspector_config_exclude_paths() {
	inspector_config_get_json '.inspector.exclude_paths // ["node_modules",".git","vendor",".venv","dist",".next",".nuxt","build","__pycache__","target","coverage"]'
}

inspector_config_checks_for_extension() {
	local ext="$1"
	[[ -z "$ext" ]] && { printf '%s\n' "[]"; return 0; }
	local raw
	raw=$(inspector_config_get_json ".inspector.checks[\"$ext\"] // []")
	[[ -z "$raw" ]] && { printf '%s\n' "[]"; return 0; }
	# Normalize bare argv arrays into objects with name, kind, argv fields
	printf '%s' "$raw" | jq -c 'map(
		if type == "array" then
			{name: .[0], kind: "lint", argv: .}
		else . end
	)'
}

#!/usr/bin/env bash
# Config resolution for Archivist.
#
# Reads three layers, latest wins:
#   1. plugins/archivist/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   archivist_config_load <repo_root>    # populates _ARCHIVIST_CONFIG (JSON)
#   archivist_config_get <jq-path>       # echoes string value (empty if unset)
#   archivist_config_enabled             # 0 if archivist.enabled is true
#
# Settings overlay only touches the `archivist.*` subtree of settings.json so it
# coexists with other plugins' configuration.

_ARCHIVIST_CONFIG="{}"

archivist_config_load() {
	local repo_root="${1:-}"
	local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
	local home_dir="${HOME:-}"

	local merged="{}"
	local file

	file="${plugin_root}/config.json"
	if [[ -f "$file" ]]; then
		local defaults
		defaults=$(jq '.' "$file" 2>/dev/null) || defaults="{}"
		merged=$(jq -n --argjson a "$merged" --argjson b "$defaults" '$a * $b' 2>/dev/null) \
			|| merged="$defaults"
	fi

	for file in "${home_dir}/.claude/settings.json" "${repo_root}/.claude/settings.json"; do
		[[ -n "$file" && -f "$file" ]] || continue
		local overlay
		overlay=$(jq '{ archivist: (.archivist // {}) }' "$file" 2>/dev/null) || continue
		[[ -z "$overlay" ]] && continue
		merged=$(jq -n --argjson a "$merged" --argjson b "$overlay" '
			def deepmerge($a; $b):
				if ($a|type) == "object" and ($b|type) == "object" then
					reduce (($a|keys) + ($b|keys) | unique)[] as $k
						({}; .[$k] = deepmerge($a[$k]; $b[$k]))
				elif $b == null then $a
				else $b end;
			deepmerge($a; $b)
		' 2>/dev/null) || true
	done

	_ARCHIVIST_CONFIG="$merged"
}

# Read a value from the loaded config. Usage:
#   archivist_config_get '.archivist.injection.max_items'
archivist_config_get() {
	local path="$1"
	printf '%s' "$_ARCHIVIST_CONFIG" | jq -r "${path} // empty" 2>/dev/null
}

# Returns 0 if archivist.enabled is true, 1 otherwise.
archivist_config_enabled() {
	local v
	v=$(archivist_config_get '.archivist.enabled')
	[[ "$v" == "true" ]]
}

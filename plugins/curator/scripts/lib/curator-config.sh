#!/usr/bin/env bash
# Config resolution for Curator.
#
# Reads three layers, latest wins:
#   1. plugins/curator/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   curator_config_load <repo_root>    # populates _CURATOR_CONFIG (JSON)
#   curator_config_get <jq-path>       # echoes string value (empty if unset)
#   curator_config_enabled             # 0 if curator.enabled is true
#
# Settings overlay only touches the `curator.*` subtree of settings.json.

_CURATOR_CONFIG="{}"

curator_config_load() {
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
		overlay=$(jq '{ curator: (.curator // {}) }' "$file" 2>/dev/null) || continue
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

	_CURATOR_CONFIG="$merged"
}

curator_config_get() {
	local path="$1"
	printf '%s' "$_CURATOR_CONFIG" | jq -r "${path} // empty" 2>/dev/null
}

curator_config_enabled() {
	local v
	v=$(curator_config_get '.curator.enabled')
	[[ "$v" == "true" ]]
}

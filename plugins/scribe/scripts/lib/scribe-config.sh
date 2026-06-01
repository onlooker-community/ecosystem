#!/usr/bin/env bash
# Config resolution for Scribe.
#
# Reads three layers, latest wins:
#   1. plugins/scribe/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   scribe_config_load <repo_root>     # populates _SCRIBE_CONFIG (JSON)
#   scribe_config_get <jq-path>        # echoes string value (empty if unset)
#   scribe_config_get_json <jq-path>   # echoes JSON value (null if unset)
#   scribe_config_enabled              # 0 if scribe.enabled is true

_SCRIBE_CONFIG="{}"

scribe_config_load() {
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

	local repo_settings=""
	[[ -n "$repo_root" ]] && repo_settings="${repo_root}/.claude/settings.json"

	for file in "${home_dir}/.claude/settings.json" "$repo_settings"; do
		[[ -n "$file" && -f "$file" ]] || continue
		local overlay
		overlay=$(jq '{ scribe: (.scribe // {}) }' "$file" 2>/dev/null) || continue
		[[ -z "$overlay" ]] && continue
		local attempt
		if attempt=$(jq -n --argjson a "$merged" --argjson b "$overlay" '
			def deepmerge($a; $b):
				if ($a|type) == "object" and ($b|type) == "object" then
					reduce (($a|keys) + ($b|keys) | unique)[] as $k
						({}; .[$k] = deepmerge($a[$k]; $b[$k]))
				elif $b == null then $a
				else $b end;
			deepmerge($a; $b)
		' 2>/dev/null) && [[ -n "$attempt" ]]; then
			merged="$attempt"
		fi
	done

	_SCRIBE_CONFIG="$merged"
}

scribe_config_get() {
	local path="$1"
	printf '%s' "$_SCRIBE_CONFIG" | jq -r "${path} // empty" 2>/dev/null
}

scribe_config_get_json() {
	local path="$1"
	printf '%s' "$_SCRIBE_CONFIG" | jq -c "${path}" 2>/dev/null
}

scribe_config_enabled() {
	local v
	v=$(scribe_config_get '.scribe.enabled')
	[[ "$v" == "true" ]]
}

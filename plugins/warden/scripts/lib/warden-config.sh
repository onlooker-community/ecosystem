#!/usr/bin/env bash
# Config resolution for Warden.
#
# Reads three layers, latest wins:
#   1. plugins/warden/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   warden_config_load <repo_root>     # populates _WARDEN_CONFIG (JSON)
#   warden_config_get <jq-path>        # echoes string value (empty if unset)
#   warden_config_get_json <jq-path>   # echoes JSON value (null if unset)
#   warden_config_enabled              # 0 if warden.enabled is true

_WARDEN_CONFIG="{}"

warden_config_load() {
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
		overlay=$(jq '{ warden: (.warden // {}) }' "$file" 2>/dev/null) || continue
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

	_WARDEN_CONFIG="$merged"
}

warden_config_get() {
	local path="$1"
	# NB: do NOT use `${path} // empty` — jq's `//` treats `false` and `0` as
	# empty, so a `false` boolean would read back as "" and a `${v:-true}`
	# default would silently flip it to true. Emit the raw value and map only a
	# literal JSON null to the empty string.
	local v
	v=$(printf '%s' "$_WARDEN_CONFIG" | jq -r "${path}" 2>/dev/null) || return 1
	[[ "$v" == "null" ]] && v=""
	printf '%s' "$v"
}

warden_config_get_json() {
	local path="$1"
	printf '%s' "$_WARDEN_CONFIG" | jq -c "${path}" 2>/dev/null
}

warden_config_enabled() {
	local v
	v=$(warden_config_get '.warden.enabled')
	[[ "$v" == "true" ]]
}

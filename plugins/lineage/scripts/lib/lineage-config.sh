#!/usr/bin/env bash
# Config resolution for lineage.
#
# Reads three layers, latest wins:
#   1. plugins/lineage/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   lineage_config_load <repo_root>     # populates _LINEAGE_CONFIG (JSON)
#   lineage_config_get <jq-path>        # echoes string value (empty if unset)
#   lineage_config_get_json <jq-path>   # echoes JSON value (null if unset)
#   lineage_config_enabled              # 0 if lineage.enabled is true
#   lineage_config_max_snippet_chars    # echoes the snippet cap (default 4000)
#   lineage_config_redact_enabled       # 0 unless redact_secrets is false
#   lineage_config_prompt_source        # echoes the prompt-source strategy
#   lineage_config_ignore_globs         # echoes ignore globs, one per line

_LINEAGE_CONFIG="{}"

lineage_config_load() {
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
		overlay=$(jq '{ lineage: (.lineage // {}) }' "$file" 2>/dev/null) || continue
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

	_LINEAGE_CONFIG="$merged"
}

lineage_config_get() {
	local path="$1"
	printf '%s' "$_LINEAGE_CONFIG" | jq -r "${path} // empty" 2>/dev/null
}

lineage_config_get_json() {
	local path="$1"
	printf '%s' "$_LINEAGE_CONFIG" | jq -c "${path}" 2>/dev/null
}

lineage_config_enabled() {
	local v
	v=$(lineage_config_get '.lineage.enabled')
	[[ "$v" == "true" ]]
}

lineage_config_max_snippet_chars() {
	local v
	v=$(lineage_config_get '.lineage.max_snippet_chars')
	printf '%s' "${v:-4000}"
}

lineage_config_redact_enabled() {
	# Default on. jq's `//` treats a literal `false` as empty, so read the raw
	# JSON value and only disable on an explicit false.
	local v
	v=$(lineage_config_get_json '.lineage.redact_secrets')
	[[ "$v" != "false" ]]
}

lineage_config_prompt_source() {
	local v
	v=$(lineage_config_get '.lineage.prompt_source')
	printf '%s' "${v:-historian_then_transcript}"
}

lineage_config_ignore_globs() {
	printf '%s' "$_LINEAGE_CONFIG" | jq -r '.lineage.ignore_globs[]? // empty' 2>/dev/null
}

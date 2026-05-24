#!/usr/bin/env bash
# Config resolution for Tribunal.
#
# Reads three layers, latest wins:
#   1. plugins/tribunal/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   tribunal_config_load <repo_root>       # populates _TRIBUNAL_CONFIG (JSON)
#   tribunal_config_get <jq-path>          # echoes string value (empty if unset)
#   tribunal_config_get_json <jq-path>     # echoes JSON value (null if unset)
#   tribunal_config_enabled                # 0 if tribunal.enabled is true
#   tribunal_config_stop_hook_enabled      # 0 if tribunal.stop_hook.enabled is true
#   tribunal_config_judge_model <judge_type>
#                                          # echoes per-judge-type model override,
#                                          # falling back to tribunal.judges.model
#
# Settings overlay only touches the `tribunal.*` subtree so this plugin coexists
# with other plugins' configuration.

_TRIBUNAL_CONFIG="{}"

tribunal_config_load() {
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
		overlay=$(jq '{ tribunal: (.tribunal // {}) }' "$file" 2>/dev/null) || continue
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

	_TRIBUNAL_CONFIG="$merged"
}

# Read a string value from the loaded config.
# Usage: tribunal_config_get '.tribunal.session.gate_policy'
tribunal_config_get() {
	local path="$1"
	printf '%s' "$_TRIBUNAL_CONFIG" | jq -r "${path} // empty" 2>/dev/null
}

# Read a JSON value (arrays, objects, numbers) from the loaded config.
# Usage: tribunal_config_get_json '.tribunal.session.judge_types'
tribunal_config_get_json() {
	local path="$1"
	printf '%s' "$_TRIBUNAL_CONFIG" | jq -c "${path}" 2>/dev/null
}

# Returns 0 if tribunal.enabled is true.
tribunal_config_enabled() {
	local v
	v=$(tribunal_config_get '.tribunal.enabled')
	[[ "$v" == "true" ]]
}

# Returns 0 if tribunal.stop_hook.enabled is true. Default is false.
tribunal_config_stop_hook_enabled() {
	local v
	v=$(tribunal_config_get '.tribunal.stop_hook.enabled')
	[[ "$v" == "true" ]]
}

# Resolve the model id for a given judge_type.
# Precedence: tribunal.judges.<type>.model > tribunal.judges.model
tribunal_config_judge_model() {
	local judge_type="$1"
	local override
	override=$(tribunal_config_get ".tribunal.judges.\"${judge_type}\".model")
	if [[ -n "$override" ]]; then
		printf '%s' "$override"
		return 0
	fi
	tribunal_config_get '.tribunal.judges.model'
}

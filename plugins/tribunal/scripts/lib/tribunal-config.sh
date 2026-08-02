#!/usr/bin/env bash
# Config resolution for tribunal.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/tribunal/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   tribunal_config_load <repo_root>    # populates _tribunal_CONFIG (JSON)
#   tribunal_config_get <jq-path>       # echoes string value (empty if unset)
#   tribunal_config_get_json <jq-path>  # echoes JSON value (null if unset)

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_TRIBUNAL_CONFIG="{}"

tribunal_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "tribunal" "$repo_root" "_TRIBUNAL_CONFIG"
	return 0
}

tribunal_config_get() {
	local path="$1"
	config_get "_TRIBUNAL_CONFIG" "${path}"
}

tribunal_config_get_json() {
	local path="$1"
	config_get_json "_TRIBUNAL_CONFIG" "${path}"
}

tribunal_config_stop_hook_enabled() {
	local v
	v=$(tribunal_config_get '.tribunal.stop_hook.enabled')
	[[ "$v" == "true" ]]
}

tribunal_config_judge_model() {
	local judge_type="${1:-}"
	local v
	if [[ -n "$judge_type" ]]; then
		v=$(tribunal_config_get ".tribunal.judges.\"$judge_type\".model")
		if [[ -n "$v" ]]; then
			printf '%s' "$v"
			return 0
		fi
	fi
	v=$(tribunal_config_get '.tribunal.judges.model')
	printf '%s' "${v:-claude-opus-4-7}"
}

#!/usr/bin/env bash
# Config resolution for curator.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/curator/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   curator_config_load <repo_root>    # populates _curator_CONFIG (JSON)
#   curator_config_get <jq-path>       # echoes string value (empty if unset)
#   curator_config_get_json <jq-path>  # echoes JSON value (null if unset)

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_curator_CONFIG="{}"

curator_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "curator" "$repo_root" "_curator_CONFIG"
	return 0
}

curator_config_get() {
	local path="$1"
	config_get "_curator_CONFIG" "${path}"
}

curator_config_get_json() {
	local path="$1"
	config_get_json "_curator_CONFIG" "${path}"
}

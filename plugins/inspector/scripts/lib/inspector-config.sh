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

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

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

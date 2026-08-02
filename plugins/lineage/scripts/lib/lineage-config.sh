#!/usr/bin/env bash
# Config resolution for lineage.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/lineage/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   lineage_config_load <repo_root>    # populates _lineage_CONFIG (JSON)
#   lineage_config_get <jq-path>       # echoes string value (empty if unset)
#   lineage_config_get_json <jq-path>  # echoes JSON value (null if unset)

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_lineage_CONFIG="{}"

lineage_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "lineage" "$repo_root" "_lineage_CONFIG"
	return 0
}

lineage_config_get() {
	local path="$1"
	config_get "_lineage_CONFIG" "${path}"
}

lineage_config_get_json() {
	local path="$1"
	config_get_json "_lineage_CONFIG" "${path}"
}

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

_tribunal_CONFIG="{}"

tribunal_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "tribunal" "$repo_root" "_tribunal_CONFIG"
	return 0
}

tribunal_config_get() {
	local path="$1"
	config_get "_tribunal_CONFIG" "${path}"
}

tribunal_config_get_json() {
	local path="$1"
	config_get_json "_tribunal_CONFIG" "${path}"
}

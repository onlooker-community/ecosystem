#!/usr/bin/env bash
# Config resolution for warden.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/warden/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   warden_config_load <repo_root>    # populates _warden_CONFIG (JSON)
#   warden_config_get <jq-path>       # echoes string value (empty if unset)
#   warden_config_get_json <jq-path>  # echoes JSON value (null if unset)

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_warden_CONFIG="{}"

warden_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "warden" "$repo_root" "_warden_CONFIG"
	return 0
}

warden_config_get() {
	local path="$1"
	config_get "_warden_CONFIG" "${path}"
}

warden_config_get_json() {
	local path="$1"
	config_get_json "_warden_CONFIG" "${path}"
}

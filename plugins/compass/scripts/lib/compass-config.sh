#!/usr/bin/env bash
# Config resolution for compass.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/compass/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   compass_config_load <repo_root>    # populates _compass_CONFIG (JSON)
#   compass_config_get <jq-path>       # echoes string value (empty if unset)
#   compass_config_get_json <jq-path>  # echoes JSON value (null if unset)

# Resolve the shared loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
_COMPASS_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/config-loader.sh
source "${_COMPASS_CONFIG_LIB_DIR}/../../../../scripts/lib/config-loader.sh"

_compass_CONFIG="{}"

compass_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "compass" "$repo_root" "_compass_CONFIG"
	return 0
}

compass_config_get() {
	local path="$1"
	config_get "_compass_CONFIG" "${path}"
}

compass_config_get_json() {
	local path="$1"
	config_get_json "_compass_CONFIG" "${path}"
}

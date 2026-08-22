#!/usr/bin/env bash
# Config resolution for Archivist.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/archivist/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   archivist_config_load <repo_root>    # populates _ARCHIVIST_CONFIG (JSON)
#   archivist_config_get <jq-path>       # echoes string value (empty if unset)
#
# Settings overlay only touches the `archivist.*` subtree of settings.json so it
# coexists with other plugins' configuration.

# Resolve the shared loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
_ARCHIVIST_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/config-loader.sh
source "${_ARCHIVIST_CONFIG_LIB_DIR}/../../../../scripts/lib/config-loader.sh"

_ARCHIVIST_CONFIG="{}"

archivist_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "archivist" "$repo_root" "_ARCHIVIST_CONFIG"
	return 0
}

# Read a value from the loaded config. Usage:
#   archivist_config_get '.archivist.injection.max_items'
archivist_config_get() {
	local path="$1"
	config_get "_ARCHIVIST_CONFIG" "${path}"
}

#!/usr/bin/env bash
# Config resolution for warden.
#
# Uses the vendored config loader (scripts/lib/config-loader.sh is canonical).
# Reads five layers, latest wins:
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

# Resolve the vendored loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
# The loader is a sibling rather than a path up to the repo root, because an
# installed plugin is its own tree with no ecosystem checkout above it.
_WARDEN_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WARDEN_CONFIG_LOADER="${_WARDEN_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_WARDEN_CONFIG_LOADER" ]]; then
	printf 'warden: missing %s — plugin package is incomplete\n' \
		"$_WARDEN_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=plugins/warden/scripts/lib/config-loader.sh
source "$_WARDEN_CONFIG_LOADER"

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

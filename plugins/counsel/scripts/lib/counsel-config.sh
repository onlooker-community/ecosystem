#!/usr/bin/env bash
# Config resolution for counsel.
#
# Uses the vendored config loader (scripts/lib/config-loader.sh is canonical).
# Reads five layers, latest wins:
#   1. plugins/counsel/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   counsel_config_load <repo_root>    # populates _counsel_CONFIG (JSON)
#   counsel_config_get <jq-path>       # echoes string value (empty if unset)
#   counsel_config_get_json <jq-path>  # echoes JSON value (null if unset)

# Resolve the vendored loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
# The loader is a sibling rather than a path up to the repo root, because an
# installed plugin is its own tree with no ecosystem checkout above it.
_COUNSEL_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_COUNSEL_CONFIG_LOADER="${_COUNSEL_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_COUNSEL_CONFIG_LOADER" ]]; then
	printf 'counsel: missing %s — plugin package is incomplete\n' \
		"$_COUNSEL_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=plugins/counsel/scripts/lib/config-loader.sh
source "$_COUNSEL_CONFIG_LOADER"

_counsel_CONFIG="{}"

counsel_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "counsel" "$repo_root" "_counsel_CONFIG"
	return 0
}

counsel_config_get() {
	local path="$1"
	config_get "_counsel_CONFIG" "${path}"
}

counsel_config_get_json() {
	local path="$1"
	config_get_json "_counsel_CONFIG" "${path}"
}

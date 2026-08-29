#!/usr/bin/env bash
# Config resolution for scribe.
#
# Uses the vendored config loader (scripts/lib/config-loader.sh is canonical).
# Reads five layers, latest wins:
#   1. plugins/scribe/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   scribe_config_load <repo_root>    # populates _scribe_CONFIG (JSON)
#   scribe_config_get <jq-path>       # echoes string value (empty if unset)
#   scribe_config_get_json <jq-path>  # echoes JSON value (null if unset)

# Resolve the vendored loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
# The loader is a sibling rather than a path up to the repo root, because an
# installed plugin is its own tree with no ecosystem checkout above it.
_SCRIBE_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCRIBE_CONFIG_LOADER="${_SCRIBE_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_SCRIBE_CONFIG_LOADER" ]]; then
	printf 'scribe: missing %s — plugin package is incomplete\n' \
		"$_SCRIBE_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=plugins/scribe/scripts/lib/config-loader.sh
source "$_SCRIBE_CONFIG_LOADER"

_scribe_CONFIG="{}"

scribe_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "scribe" "$repo_root" "_scribe_CONFIG"
	return 0
}

scribe_config_get() {
	local path="$1"
	config_get "_scribe_CONFIG" "${path}"
}

scribe_config_get_json() {
	local path="$1"
	config_get_json "_scribe_CONFIG" "${path}"
}

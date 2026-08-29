#!/usr/bin/env bash
# Config resolution for Librarian.
#
# Uses the vendored config loader (scripts/lib/config-loader.sh is canonical).
# Reads five layers, latest wins:
#   1. plugins/librarian/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   librarian_config_load <repo_root>    # populates _LIBRARIAN_CONFIG (JSON)
#   librarian_config_get <jq-path>       # echoes string value (empty if unset)
#   librarian_config_auto_promote        # 0 if librarian.auto_promote is true
#
# Settings overlay only touches the `librarian.*` subtree of settings.json so
# it coexists with other plugins' configuration.

# Resolve the vendored loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
# The loader is a sibling rather than a path up to the repo root, because an
# installed plugin is its own tree with no ecosystem checkout above it.
_LIBRARIAN_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIBRARIAN_CONFIG_LOADER="${_LIBRARIAN_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_LIBRARIAN_CONFIG_LOADER" ]]; then
	printf 'librarian: missing %s — plugin package is incomplete\n' \
		"$_LIBRARIAN_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=plugins/librarian/scripts/lib/config-loader.sh
source "$_LIBRARIAN_CONFIG_LOADER"

_LIBRARIAN_CONFIG="{}"

librarian_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "librarian" "$repo_root" "_LIBRARIAN_CONFIG"
	return 0
}

# Read a value from the loaded config. Usage:
#   librarian_config_get '.librarian.surfacer.max_pending_for_inject'
librarian_config_get() {
	local path="$1"
	config_get "_LIBRARIAN_CONFIG" "${path}"
}

# Returns 0 if librarian.auto_promote is true, 1 otherwise.
librarian_config_auto_promote() {
	local v
	v=$(librarian_config_get '.librarian.auto_promote')
	[[ "$v" == "true" ]]
}

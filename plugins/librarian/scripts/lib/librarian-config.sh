#!/usr/bin/env bash
# Config resolution for Librarian.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
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

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

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

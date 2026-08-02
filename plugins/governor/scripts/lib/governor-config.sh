#!/usr/bin/env bash
# Config resolution for Governor.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/governor/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   governor_config_load <repo_root>     # populates _GOVERNOR_CONFIG (JSON)
#   governor_config_get <jq-path>        # echoes string value (empty if unset)
#   governor_config_get_json <jq-path>   # echoes JSON value (null if unset)
#   governor_config_enforcement          # echoes "soft" or "hard"

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_GOVERNOR_CONFIG="{}"

governor_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "governor" "$repo_root" "_GOVERNOR_CONFIG"
	return 0
}

governor_config_get() {
	local path="$1"
	config_get "_GOVERNOR_CONFIG" "${path}"
}

governor_config_get_json() {
	local path="$1"
	config_get_json "_GOVERNOR_CONFIG" "${path}"
}

governor_config_enforcement() {
	local v
	v=$(governor_config_get '.governor.enforcement')
	printf '%s' "${v:-soft}"
}

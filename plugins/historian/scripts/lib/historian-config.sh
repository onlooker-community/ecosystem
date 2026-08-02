#!/usr/bin/env bash
# Config resolution for Historian.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/historian/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   historian_config_load <repo_root>    # populates _HISTORIAN_CONFIG (JSON)
#   historian_config_get <jq-path>       # echoes string value (empty if unset)
#
# Settings overlay only touches the `historian.*` subtree of settings.json.

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_HISTORIAN_CONFIG="{}"

historian_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "historian" "$repo_root" "_HISTORIAN_CONFIG"
	return 0
}

# Read a value from the loaded config. The explicit null check (instead of
# `// empty`) preserves boolean `false` — `// empty` would treat it the same
# as null and silently drop "explicitly disabled" settings.
historian_config_get() {
	local path="$1"
	printf '%s' "$_HISTORIAN_CONFIG" \
		| jq -r "${path} | if . == null then empty else . end" 2>/dev/null
}


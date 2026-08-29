#!/usr/bin/env bash
# Config resolution for Historian.
#
# Uses the vendored config loader (scripts/lib/config-loader.sh is canonical).
# Reads five layers, latest wins:
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

# Resolve the vendored loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
# The loader is a sibling rather than a path up to the repo root, because an
# installed plugin is its own tree with no ecosystem checkout above it.
_HISTORIAN_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HISTORIAN_CONFIG_LOADER="${_HISTORIAN_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_HISTORIAN_CONFIG_LOADER" ]]; then
	printf 'historian: missing %s — plugin package is incomplete\n' \
		"$_HISTORIAN_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=plugins/historian/scripts/lib/config-loader.sh
source "$_HISTORIAN_CONFIG_LOADER"

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


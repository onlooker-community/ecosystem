#!/usr/bin/env bash
# Config resolution for Governor.
#
# Uses the vendored config loader (scripts/lib/config-loader.sh is canonical).
# Reads five layers, latest wins:
#   1. plugins/governor/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <worktree>/.claude/settings.json
#   5. <parent>/.claude/settings.local.json (local overrides project)
#
# Layers 4 and 5 resolve against DIFFERENT roots. settings.json is committed and
# therefore branch-scoped; settings.local.json is gitignored, so git worktree add
# never copies it and it lives only in the main checkout. config_load_plugin
# takes a session cwd and derives both roots itself (ecosystem-449.37).
#
# Exposes:
#   governor_config_load <cwd>     # populates _GOVERNOR_CONFIG (JSON)
#   governor_config_get <jq-path>        # echoes string value (empty if unset)
#   governor_config_get_json <jq-path>   # echoes JSON value (null if unset)
#   governor_config_int <jq-path> <default>  # echoes a non-negative integer
#   governor_config_enforcement          # echoes "soft" or "hard"

# Resolve the vendored loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
# The loader is a sibling rather than a path up to the repo root, because an
# installed plugin is its own tree with no ecosystem checkout above it.
_GOVERNOR_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_GOVERNOR_CONFIG_LOADER="${_GOVERNOR_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_GOVERNOR_CONFIG_LOADER" ]]; then
	printf 'governor: missing %s — plugin package is incomplete\n' \
		"$_GOVERNOR_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=plugins/governor/scripts/lib/config-loader.sh
source "$_GOVERNOR_CONFIG_LOADER"

_GOVERNOR_CONFIG="{}"

governor_config_load() {
	local cwd="${1:-}"
	config_load_plugin "governor" "$cwd" "_GOVERNOR_CONFIG"
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

# Read a value that is about to reach arithmetic. The fallback idioms this
# replaces catch an empty value and the literal "null" and nothing else, so any
# other non-numeric value passed through to (( )), where bash reads the bare
# word as a variable name and set -u stops the shell -- at status 0, because
# these scripts run set -uo pipefail deliberately without -e (ONL-132).
#
# config_get_int always prints a non-negative integer, falling back to $2 for
# anything failing ^[0-9]+$. Do not use it for floats (temperature, margins).
governor_config_int() {
	local path="$1"
	local default="$2"
	config_get_int "_GOVERNOR_CONFIG" "${path}" "${default}"
}

governor_config_enforcement() {
	local v
	v=$(governor_config_get '.governor.enforcement')
	printf '%s' "${v:-soft}"
}

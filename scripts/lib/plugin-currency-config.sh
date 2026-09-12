#!/usr/bin/env bash
# Config resolution for the plugin-currency surfacer (ecosystem-449.59).
#
# Five layers, latest wins:
#   1. <repo>/config.json  (the substrate's shipped defaults)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json
#
# Exposes:
#   plugin_currency_config_load <repo_root>    # populates _PLUGIN_CURRENCY_CONFIG
#   plugin_currency_config_get <jq-path>       # string value, empty if unset
#   plugin_currency_config_get_json <jq-path>  # JSON value, null if unset
#
# Paths include the namespace key, matching every other accessor in the repo:
#   plugin_currency_config_get '.plugin_currency.probe_ttl_hours'

# Resolve the loader from this file's own location rather than from a
# caller-supplied $PLUGIN_ROOT. $PLUGIN_ROOT is read at source time from
# whatever scope did the sourcing, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor here while
# the script still exited 0 — config would fall back to shipped defaults with
# no error to show for it.
_PC_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PC_CONFIG_LOADER="${_PC_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_PC_CONFIG_LOADER" ]]; then
	printf 'plugin-currency: missing %s — package is incomplete\n' \
		"$_PC_CONFIG_LOADER" >&2
	return 1 2>/dev/null || exit 1
fi
# shellcheck source=scripts/lib/config-loader.sh
source "$_PC_CONFIG_LOADER"

_PLUGIN_CURRENCY_CONFIG="{}"

plugin_currency_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "plugin_currency" "$repo_root" "_PLUGIN_CURRENCY_CONFIG"
	return 0
}

plugin_currency_config_get() {
	local path="$1"
	config_get "_PLUGIN_CURRENCY_CONFIG" "${path}"
}

plugin_currency_config_get_json() {
	local path="$1"
	config_get_json "_PLUGIN_CURRENCY_CONFIG" "${path}"
}

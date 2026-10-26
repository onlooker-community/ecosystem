#!/usr/bin/env bash
# Config resolution for customs.
#
# Uses the vendored config loader (scripts/lib/config-loader.sh is canonical),
# so customs reads the same five layers as every plugin: its own config.json,
# then user and project settings, latest wins. See warden-config.sh for the
# layer order and why settings.local.json resolves against a different root.
#
# The loader's deepmerge REPLACES arrays. That is why the built-in kind x host
# pairs live in customs-allowlist.sh rather than here: in config.json, one user
# pair for a kind would silently drop that kind's built-in hosts.
#
# Exposes:
#   customs_config_load <cwd>           # populates _customs_CONFIG (JSON)
#   customs_config_get <jq-path>        # echoes string value (empty if unset)
#   customs_config_get_json <jq-path>   # echoes JSON value (null if unset)

_CUSTOMS_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CUSTOMS_CONFIG_LOADER="${_CUSTOMS_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_CUSTOMS_CONFIG_LOADER" ]]; then
	printf 'customs: missing %s — plugin package is incomplete\n' \
		"$_CUSTOMS_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=plugins/customs/scripts/lib/config-loader.sh
source "$_CUSTOMS_CONFIG_LOADER"

_customs_CONFIG="{}"

customs_config_load() {
	local cwd="${1:-}"
	config_load_plugin "customs" "$cwd" "_customs_CONFIG"
	return 0
}

customs_config_get() {
	config_get "_customs_CONFIG" "${1:-}"
}

customs_config_get_json() {
	config_get_json "_customs_CONFIG" "${1:-}"
}

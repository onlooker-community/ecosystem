#!/usr/bin/env bash
# Config resolution for bursar.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/bursar/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   bursar_config_load <repo_root>     # populates _BURSAR_CONFIG (JSON)
#   bursar_config_get <jq-path>        # echoes string value (empty if unset)
#   bursar_config_get_json <jq-path>   # echoes JSON value (null if unset)
#   bursar_config_window               # echoes "rolling_7d" or "calendar_week"
#   bursar_config_surface_enabled      # 0 if bursar.surface_at_session_start is true
#   bursar_config_week_start           # echoes "monday" or "sunday"

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_BURSAR_CONFIG="{}"

bursar_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "bursar" "$repo_root" "_BURSAR_CONFIG"
	return 0
}

bursar_config_get() {
	local path="$1"
	config_get "_BURSAR_CONFIG" "${path}"
}

bursar_config_get_json() {
	local path="$1"
	config_get_json "_BURSAR_CONFIG" "${path}"
}

bursar_config_surface_enabled() {
	# Use the JSON getter, not bursar_config_get: jq's `//` treats a literal
	# `false` as empty, which would mask an explicit opt-out. The JSON getter
	# returns the raw `false`/`true`/`null` so the default-on behavior holds.
	local v
	v=$(bursar_config_get_json '.bursar.surface_at_session_start')
	# Default to surfacing unless explicitly set to false.
	[[ "$v" != "false" ]]
}

bursar_config_window() {
	local v
	v=$(bursar_config_get '.bursar.window')
	case "$v" in
		calendar_week) printf 'calendar_week' ;;
		*) printf 'rolling_7d' ;;
	esac
}

bursar_config_week_start() {
	local v
	v=$(bursar_config_get '.bursar.week_start')
	case "$v" in
		sunday) printf 'sunday' ;;
		*) printf 'monday' ;;
	esac
}

bursar_config_min_cost() {
	local v
	v=$(bursar_config_get '.bursar.min_cost_to_surface_usd')
	printf '%s' "${v:-0}"
}

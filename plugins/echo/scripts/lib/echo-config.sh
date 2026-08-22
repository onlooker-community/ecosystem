#!/usr/bin/env bash
# Config resolution for echo.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/echo/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   echo_config_load <repo_root>    # populates _echo_CONFIG (JSON)
#   echo_config_get <jq-path>       # echoes string value (empty if unset)
#   echo_config_get_json <jq-path>  # echoes JSON value (null if unset)

# Resolve the shared loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
_ECHO_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/config-loader.sh
source "${_ECHO_CONFIG_LIB_DIR}/../../../../scripts/lib/config-loader.sh"

_echo_CONFIG="{}"

echo_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "echo" "$repo_root" "_echo_CONFIG"
	return 0
}

echo_config_get() {
	local path="$1"
	config_get "_echo_CONFIG" "${path}"
}

echo_config_get_json() {
	local path="$1"
	config_get_json "_echo_CONFIG" "${path}"
}

echo_config_model() {
	local val
	val=$(echo_config_get '.echo.evaluation.model')
	printf '%s' "${val:-claude-haiku-4-5-20251001}"
}

echo_config_timeout() {
	local val
	val=$(echo_config_get '.echo.evaluation.timeout_seconds')
	printf '%s' "${val:-60}"
}

echo_config_drift_threshold() {
	local val
	val=$(echo_config_get '.echo.drift_threshold')
	printf '%s' "${val:-0.05}"
}

echo_config_watch_paths() {
	local raw
	raw=$(echo_config_get_json '.echo.watch_paths')
	if [[ -n "$raw" && "$raw" != "null" ]]; then
		printf '%s' "$raw" | jq -r '.[]' 2>/dev/null
	else
		printf 'plugins/*/agents/*.md\n'
	fi
}

echo_config_exclude_paths() {
	local raw
	raw=$(echo_config_get_json '.echo.exclude_paths')
	if [[ -n "$raw" && "$raw" != "null" ]]; then
		printf '%s' "$raw" | jq -r '.[]' 2>/dev/null
	fi
	# Always exclude Echo's own tree — hardcoded, not overridable.
	printf 'plugins/echo/**\n'
}

#!/usr/bin/env bash
# cartographer-config.sh — load and query Cartographer configuration.
#
# Merges three layers in precedence order (later wins):
#   1. plugins/cartographer/config.json  (plugin defaults)
#   2. ~/.claude/settings.json           (.cartographer subtree)
#   3. <repo>/.claude/settings.json      (.cartographer subtree)
#
# Usage:
#   cartographer_config_load <repo_root>
#   cartographer_config_get ".cartographer.enabled"
#   cartographer_config_get_json ".cartographer.exclude_paths"

_CARTOGRAPHER_CONFIG=""
_CARTOGRAPHER_PLUGIN_CONFIG=""

cartographer_config_load() {
	local repo_root="${1:-}"
	local plugin_dir
	plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	local plugin_config="$plugin_dir/config.json"

	_CARTOGRAPHER_PLUGIN_CONFIG="{}"
	if [[ -f "$plugin_config" ]]; then
		_CARTOGRAPHER_PLUGIN_CONFIG=$(cat "$plugin_config")
	fi

	local home_settings="{}"
	if [[ -f "$HOME/.claude/settings.json" ]]; then
		home_settings=$(cat "$HOME/.claude/settings.json")
	fi

	local repo_settings="{}"
	if [[ -n "$repo_root" && -f "$repo_root/.claude/settings.json" ]]; then
		repo_settings=$(cat "$repo_root/.claude/settings.json")
	fi

	_CARTOGRAPHER_CONFIG=$(jq -n \
		--argjson plugin "$_CARTOGRAPHER_PLUGIN_CONFIG" \
		--argjson home "$home_settings" \
		--argjson repo "$repo_settings" \
		'$plugin * {"cartographer": (($plugin.cartographer // {}) * ($home.cartographer // {}) * ($repo.cartographer // {}))}')
}

cartographer_config_get() {
	local path="${1:-}"
	printf '%s' "$_CARTOGRAPHER_CONFIG" | jq -r "$path // empty" 2>/dev/null
}

cartographer_config_get_json() {
	local path="${1:-}"
	printf '%s' "$_CARTOGRAPHER_CONFIG" | jq -c "$path // empty" 2>/dev/null
}

cartographer_config_enabled() {
	local v
	v=$(cartographer_config_get '.cartographer.enabled')
	[[ "$v" == "true" ]]
}

cartographer_config_model_extraction() {
	local v
	v=$(cartographer_config_get '.cartographer.extraction.model')
	printf '%s' "${v:-claude-haiku-4-5-20251001}"
}

cartographer_config_model_synthesis() {
	local v
	v=$(cartographer_config_get '.cartographer.synthesis.model')
	printf '%s' "${v:-claude-haiku-4-5-20251001}"
}

cartographer_config_phase_timeout() {
	local v
	v=$(cartographer_config_get '.cartographer.phase_timeout_seconds')
	printf '%s' "${v:-60}"
}

cartographer_config_total_timeout() {
	local v
	v=$(cartographer_config_get '.cartographer.total_timeout_seconds')
	printf '%s' "${v:-600}"
}

cartographer_config_audit_interval_hours() {
	local v
	v=$(cartographer_config_get '.cartographer.audit_interval_hours')
	printf '%s' "${v:-24}"
}

cartographer_config_exclude_paths() {
	cartographer_config_get_json '.cartographer.exclude_paths // ["node_modules",".git","vendor",".venv","dist",".next",".nuxt","build","__pycache__"]'
}

cartographer_config_max_output_tokens_extraction() {
	local v
	v=$(cartographer_config_get '.cartographer.extraction.max_output_tokens')
	printf '%s' "${v:-2048}"
}

cartographer_config_max_output_tokens_synthesis() {
	local v
	v=$(cartographer_config_get '.cartographer.synthesis.max_output_tokens')
	printf '%s' "${v:-2048}"
}

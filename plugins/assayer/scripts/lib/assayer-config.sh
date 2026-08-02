#!/usr/bin/env bash
# Config resolution for assayer.
#
# Uses the shared config loader from ecosystem. Reads five layers, latest wins:
#   1. plugins/assayer/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)
#
# Exposes:
#   assayer_config_load <repo_root>    # populates _assayer_CONFIG (JSON)
#   assayer_config_get <jq-path>       # echoes string value (empty if unset)
#   assayer_config_get_json <jq-path>  # echoes JSON value (null if unset)

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_assayer_CONFIG="{}"

assayer_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "assayer" "$repo_root" "_assayer_CONFIG"
	return 0
}

assayer_config_get() {
	local path="$1"
	config_get "_assayer_CONFIG" "${path}"
}

assayer_config_get_json() {
	local path="$1"
	config_get_json "_assayer_CONFIG" "${path}"
}

assayer_config_model() {
	local v
	v=$(assayer_config_get '.assayer.evaluation.model')
	printf '%s' "${v:-claude-haiku-4-5-20251001}"
}

assayer_config_max_claims() {
	local v
	v=$(assayer_config_get '.assayer.max_claims')
	printf '%s' "${v:-12}"
}

assayer_config_min_confidence() {
	local v
	v=$(assayer_config_get '.assayer.min_confidence')
	printf '%s' "${v:-0.5}"
}

assayer_config_timeout() {
	local v
	v=$(assayer_config_get '.assayer.evaluation.timeout_seconds')
	printf '%s' "${v:-60}"
}

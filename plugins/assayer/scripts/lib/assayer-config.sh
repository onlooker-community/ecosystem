#!/usr/bin/env bash
# Config loading for Assayer.
# Reads the repo's .claude/settings.json assayer.* keys, falling back to the
# plugin's own config.json defaults.

_ASSAYER_CONFIG_JSON=""
_ASSAYER_PLUGIN_CONFIG_JSON=""

assayer_config_load() {
	local repo_root="${1:-}"

	_ASSAYER_PLUGIN_CONFIG_JSON=""
	local plugin_config="${CLAUDE_PLUGIN_ROOT:-}/config.json"
	if [[ -f "$plugin_config" ]]; then
		_ASSAYER_PLUGIN_CONFIG_JSON=$(cat "$plugin_config" 2>/dev/null) || _ASSAYER_PLUGIN_CONFIG_JSON=""
	fi

	_ASSAYER_CONFIG_JSON=""
	if [[ -n "$repo_root" ]]; then
		local settings_file="${repo_root}/.claude/settings.json"
		if [[ -f "$settings_file" ]]; then
			local settings
			settings=$(cat "$settings_file" 2>/dev/null) || settings=""
			local block
			block=$(printf '%s' "$settings" | jq -c '.assayer // empty' 2>/dev/null) || block=""
			[[ -n "$block" ]] && _ASSAYER_CONFIG_JSON="$block"
		fi
	fi
}

# Get a single scalar value. Checks settings.json first, then plugin config.json.
assayer_config_get() {
	local key="$1"

	if [[ -n "$_ASSAYER_CONFIG_JSON" ]]; then
		local val
		val=$(printf '%s' "$_ASSAYER_CONFIG_JSON" | jq -r "${key} // empty" 2>/dev/null) || val=""
		[[ -n "$val" && "$val" != "null" ]] && {
			printf '%s' "$val"
			return 0
		}
	fi

	if [[ -n "$_ASSAYER_PLUGIN_CONFIG_JSON" ]]; then
		local val
		val=$(printf '%s' "$_ASSAYER_PLUGIN_CONFIG_JSON" | jq -r ".assayer${key} // empty" 2>/dev/null) || val=""
		[[ -n "$val" && "$val" != "null" ]] && {
			printf '%s' "$val"
			return 0
		}
	fi
}

assayer_config_model() {
	local val
	val=$(assayer_config_get '.evaluation.model')
	printf '%s' "${val:-claude-haiku-4-5-20251001}"
}

assayer_config_timeout() {
	local val
	val=$(assayer_config_get '.evaluation.timeout_seconds')
	printf '%s' "${val:-60}"
}

assayer_config_max_claims() {
	local val
	val=$(assayer_config_get '.max_claims')
	printf '%s' "${val:-12}"
}

assayer_config_min_confidence() {
	local val
	val=$(assayer_config_get '.min_confidence')
	printf '%s' "${val:-0.5}"
}

assayer_config_final_message_chars() {
	local val
	val=$(assayer_config_get '.final_message_chars')
	printf '%s' "${val:-6000}"
}

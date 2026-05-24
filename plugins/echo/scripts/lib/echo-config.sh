#!/usr/bin/env bash
# Config loading for Echo.
# Reads config.json from the repo's .claude/settings.json echo.* keys,
# falling back to the plugin's own config.json defaults.

_ECHO_CONFIG_JSON=""
_ECHO_PLUGIN_CONFIG_JSON=""

echo_config_load() {
	local repo_root="${1:-}"

	_ECHO_PLUGIN_CONFIG_JSON=""
	local plugin_config="${CLAUDE_PLUGIN_ROOT:-}/config.json"
	if [[ -f "$plugin_config" ]]; then
		_ECHO_PLUGIN_CONFIG_JSON=$(cat "$plugin_config" 2>/dev/null) || _ECHO_PLUGIN_CONFIG_JSON=""
	fi

	_ECHO_CONFIG_JSON=""
	if [[ -n "$repo_root" ]]; then
		local settings_file="${repo_root}/.claude/settings.json"
		if [[ -f "$settings_file" ]]; then
			local settings
			settings=$(cat "$settings_file" 2>/dev/null) || settings=""
			local echo_block
			echo_block=$(printf '%s' "$settings" | jq -c '.echo // empty' 2>/dev/null) || echo_block=""
			[[ -n "$echo_block" ]] && _ECHO_CONFIG_JSON="$echo_block"
		fi
	fi
}

# Get a single scalar value. Checks settings.json first, then plugin config.json.
echo_config_get() {
	local key="$1"

	if [[ -n "$_ECHO_CONFIG_JSON" ]]; then
		local val
		val=$(printf '%s' "$_ECHO_CONFIG_JSON" | jq -r "${key} // empty" 2>/dev/null) || val=""
		[[ -n "$val" && "$val" != "null" ]] && { printf '%s' "$val"; return 0; }
	fi

	if [[ -n "$_ECHO_PLUGIN_CONFIG_JSON" ]]; then
		local val
		val=$(printf '%s' "$_ECHO_PLUGIN_CONFIG_JSON" | jq -r ".echo${key} // empty" 2>/dev/null) || val=""
		[[ -n "$val" && "$val" != "null" ]] && { printf '%s' "$val"; return 0; }
	fi
}

echo_config_get_json() {
	local key="$1"

	if [[ -n "$_ECHO_CONFIG_JSON" ]]; then
		local val
		val=$(printf '%s' "$_ECHO_CONFIG_JSON" | jq -c "${key} // empty" 2>/dev/null) || val=""
		[[ -n "$val" && "$val" != "null" && "$val" != "empty" ]] && { printf '%s' "$val"; return 0; }
	fi

	if [[ -n "$_ECHO_PLUGIN_CONFIG_JSON" ]]; then
		local val
		val=$(printf '%s' "$_ECHO_PLUGIN_CONFIG_JSON" | jq -c ".echo${key} // empty" 2>/dev/null) || val=""
		[[ -n "$val" && "$val" != "null" && "$val" != "empty" ]] && { printf '%s' "$val"; return 0; }
	fi
}

echo_config_enabled() {
	local val
	val=$(echo_config_get '.enabled')
	[[ "$val" == "true" ]]
}

echo_config_model() {
	local val
	val=$(echo_config_get '.evaluation.model')
	printf '%s' "${val:-claude-haiku-4-5-20251001}"
}

echo_config_timeout() {
	local val
	val=$(echo_config_get '.evaluation.timeout_seconds')
	printf '%s' "${val:-60}"
}

echo_config_drift_threshold() {
	local val
	val=$(echo_config_get '.drift_threshold')
	printf '%s' "${val:-0.05}"
}

# Prints newline-separated list of watch glob patterns.
echo_config_watch_paths() {
	local raw
	raw=$(echo_config_get_json '.watch_paths')
	if [[ -n "$raw" ]]; then
		printf '%s' "$raw" | jq -r '.[]' 2>/dev/null
	else
		printf 'plugins/*/agents/*.md\n'
	fi
}

# Prints newline-separated list of exclude glob patterns.
echo_config_exclude_paths() {
	local raw
	raw=$(echo_config_get_json '.exclude_paths')
	if [[ -n "$raw" ]]; then
		printf '%s' "$raw" | jq -r '.[]' 2>/dev/null
	fi
	# Always exclude Echo's own tree — hardcoded, not overridable.
	printf 'plugins/echo/**\n'
}

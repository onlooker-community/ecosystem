#!/usr/bin/env bash
# Config resolution for bursar.
#
# Reads three layers, latest wins:
#   1. plugins/bursar/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   bursar_config_load <repo_root>     # populates _BURSAR_CONFIG (JSON)
#   bursar_config_get <jq-path>        # echoes string value (empty if unset)
#   bursar_config_get_json <jq-path>   # echoes JSON value (null if unset)
#   bursar_config_enabled              # 0 if bursar.enabled is true
#   bursar_config_window               # echoes "rolling_7d" or "calendar_week"
#   bursar_config_week_start           # echoes "monday" or "sunday"

_BURSAR_CONFIG="{}"

bursar_config_load() {
	local repo_root="${1:-}"
	local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
	local home_dir="${HOME:-}"

	local merged="{}"
	local file

	file="${plugin_root}/config.json"
	if [[ -f "$file" ]]; then
		local defaults
		defaults=$(jq '.' "$file" 2>/dev/null) || defaults="{}"
		merged=$(jq -n --argjson a "$merged" --argjson b "$defaults" '$a * $b' 2>/dev/null) \
			|| merged="$defaults"
	fi

	local repo_settings=""
	[[ -n "$repo_root" ]] && repo_settings="${repo_root}/.claude/settings.json"

	for file in "${home_dir}/.claude/settings.json" "$repo_settings"; do
		[[ -n "$file" && -f "$file" ]] || continue
		local overlay
		overlay=$(jq '{ bursar: (.bursar // {}) }' "$file" 2>/dev/null) || continue
		[[ -z "$overlay" ]] && continue
		local attempt
		if attempt=$(jq -n --argjson a "$merged" --argjson b "$overlay" '
			def deepmerge($a; $b):
				if ($a|type) == "object" and ($b|type) == "object" then
					reduce (($a|keys) + ($b|keys) | unique)[] as $k
						({}; .[$k] = deepmerge($a[$k]; $b[$k]))
				elif $b == null then $a
				else $b end;
			deepmerge($a; $b)
		' 2>/dev/null) && [[ -n "$attempt" ]]; then
			merged="$attempt"
		fi
	done

	_BURSAR_CONFIG="$merged"
}

bursar_config_get() {
	local path="$1"
	printf '%s' "$_BURSAR_CONFIG" | jq -r "${path} // empty" 2>/dev/null
}

bursar_config_get_json() {
	local path="$1"
	printf '%s' "$_BURSAR_CONFIG" | jq -c "${path}" 2>/dev/null
}

bursar_config_enabled() {
	local v
	v=$(bursar_config_get '.bursar.enabled')
	[[ "$v" == "true" ]]
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

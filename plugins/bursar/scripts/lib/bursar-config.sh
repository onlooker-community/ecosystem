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
#   bursar_config_window               # echoes "rolling_7d" or "calendar_week"
#   bursar_config_surface_enabled      # 0 if bursar.surface_at_session_start is true
#   bursar_config_week_start           # echoes "monday" or "sunday"

_BURSAR_CONFIG="{}"

bursar_config_load() {
	local repo_root="${1:-}"
	local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
	local home_dir="${HOME:-}"

	# Read each layer's raw text with the no-fork `$(<file)` builtin (NOT `cat`),
	# then deep-merge all three layers in a SINGLE jq invocation. The dominant
	# cost in the SessionEnd hook is jq process startup, not the merge itself, so
	# this collapses what was one-jq-per-file (up to 6 forks) down to one.
	local default_txt="" home_txt="" repo_txt=""
	local default_file="${plugin_root}/config.json"
	local home_file="${home_dir}/.claude/settings.json"
	local repo_file=""
	[[ -n "$repo_root" ]] && repo_file="${repo_root}/.claude/settings.json"

	[[ -f "$default_file" ]] && default_txt="$(<"$default_file")"
	[[ -f "$home_file" ]] && home_txt="$(<"$home_file")"
	[[ -n "$repo_file" && -f "$repo_file" ]] && repo_txt="$(<"$repo_file")"

	# Precedence (latest wins): defaults < home settings < repo settings. The
	# defaults file is merged whole; settings files contribute only their .bursar
	# key. `fromjson? // {}` parses each layer defensively — a missing or malformed
	# file degrades to {} rather than aborting the merge (matches the prior
	# per-file fallback).
	_BURSAR_CONFIG=$(jq -n \
		--arg d "$default_txt" \
		--arg h "$home_txt" \
		--arg r "$repo_txt" \
		'
		def deepmerge($a; $b):
			if ($a|type) == "object" and ($b|type) == "object" then
				reduce (($a|keys) + ($b|keys) | unique)[] as $k
					({}; .[$k] = deepmerge($a[$k]; $b[$k]))
			elif $b == null then $a
			else $b end;
		($d | fromjson? // {}) as $defaults
		| (($h | fromjson? // {}) | {bursar: (.bursar // {})}) as $home
		| (($r | fromjson? // {}) | {bursar: (.bursar // {})}) as $repo
		| deepmerge(deepmerge($defaults; $home); $repo)
		' 2>/dev/null) || _BURSAR_CONFIG="{}"
	[[ -z "$_BURSAR_CONFIG" ]] && _BURSAR_CONFIG="{}"
	return 0
}

bursar_config_get() {
	local path="$1"
	printf '%s' "$_BURSAR_CONFIG" | jq -r "${path} // empty" 2>/dev/null
}

bursar_config_get_json() {
	local path="$1"
	printf '%s' "$_BURSAR_CONFIG" | jq -c "${path}" 2>/dev/null
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

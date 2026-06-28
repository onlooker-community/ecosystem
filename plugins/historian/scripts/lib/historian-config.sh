#!/usr/bin/env bash
# Config resolution for Historian.
#
# Reads three layers, latest wins:
#   1. plugins/historian/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   historian_config_load <repo_root>    # populates _HISTORIAN_CONFIG (JSON)
#   historian_config_get <jq-path>       # echoes string value (empty if unset)
#
# Settings overlay only touches the `historian.*` subtree of settings.json.

_HISTORIAN_CONFIG="{}"

historian_config_load() {
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

	for file in "${home_dir}/.claude/settings.json" "${repo_root}/.claude/settings.json"; do
		[[ -n "$file" && -f "$file" ]] || continue
		local overlay
		overlay=$(jq '{ historian: (.historian // {}) }' "$file" 2>/dev/null) || continue
		[[ -z "$overlay" ]] && continue
		merged=$(jq -n --argjson a "$merged" --argjson b "$overlay" '
			def deepmerge($a; $b):
				if ($a|type) == "object" and ($b|type) == "object" then
					reduce (($a|keys) + ($b|keys) | unique)[] as $k
						({}; .[$k] = deepmerge($a[$k]; $b[$k]))
				elif $b == null then $a
				else $b end;
			deepmerge($a; $b)
		' 2>/dev/null) || true
	done

	_HISTORIAN_CONFIG="$merged"
}

# Read a value from the loaded config. The explicit null check (instead of
# `// empty`) preserves boolean `false` — `// empty` would treat it the same
# as null and silently drop "explicitly disabled" settings.
historian_config_get() {
	local path="$1"
	printf '%s' "$_HISTORIAN_CONFIG" \
		| jq -r "${path} | if . == null then empty else . end" 2>/dev/null
}


#!/usr/bin/env bash
# Config resolution for Librarian.
#
# Reads three layers, latest wins:
#   1. plugins/librarian/config.json (defaults shipped with the plugin)
#   2. ~/.claude/settings.json
#   3. <repo>/.claude/settings.json
#
# Exposes:
#   librarian_config_load <repo_root>    # populates _LIBRARIAN_CONFIG (JSON)
#   librarian_config_get <jq-path>       # echoes string value (empty if unset)
#   librarian_config_enabled             # 0 if librarian.enabled is true
#   librarian_config_auto_promote        # 0 if librarian.auto_promote is true
#
# Settings overlay only touches the `librarian.*` subtree of settings.json so
# it coexists with other plugins' configuration.

_LIBRARIAN_CONFIG="{}"

librarian_config_load() {
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
		overlay=$(jq '{ librarian: (.librarian // {}) }' "$file" 2>/dev/null) || continue
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

	_LIBRARIAN_CONFIG="$merged"
}

# Read a value from the loaded config. Usage:
#   librarian_config_get '.librarian.surfacer.max_pending_for_inject'
librarian_config_get() {
	local path="$1"
	printf '%s' "$_LIBRARIAN_CONFIG" | jq -r "${path} // empty" 2>/dev/null
}

# Returns 0 if librarian.enabled is true, 1 otherwise.
librarian_config_enabled() {
	local v
	v=$(librarian_config_get '.librarian.enabled')
	[[ "$v" == "true" ]]
}

# Returns 0 if librarian.auto_promote is true, 1 otherwise.
librarian_config_auto_promote() {
	local v
	v=$(librarian_config_get '.librarian.auto_promote')
	[[ "$v" == "true" ]]
}

#!/usr/bin/env bash
# Shared config loader for Onlooker plugins.
#
# Plugins use this to avoid duplicating config merging logic. Handles all five
# layers of settings precedence in a single jq pass, with consistent behavior
# across the ecosystem.
#
# Usage:
#   # In your plugin's config loader (e.g., plugins/bursar/scripts/lib/bursar-config.sh).
#   # Locate this file from the sourcing file's OWN path, never from a
#   # caller-supplied $PLUGIN_ROOT: that variable is read at source time from
#   # whatever scope did the sourcing, so a sub-shell that inherits
#   # CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT loses every accessor below while
#   # still exiting 0 (see ecosystem-88v, ecosystem-7bj). Four levels up from
#   # plugins/<name>/scripts/lib is the repo root.
#   _BURSAR_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=scripts/lib/config-loader.sh
#   source "${_BURSAR_CONFIG_LIB_DIR}/../../../../scripts/lib/config-loader.sh"
#
#   The shellcheck directive is repo-root-relative, not file-relative: shellcheck
#   resolves source= against its own working directory, and `npm run
#   test:shellcheck` runs it from the repo root. A file-relative path there
#   silently degrades to SC1091 "not following", which `-S error` hides.
#   config_load_plugin "bursar" "$repo_root" "_BURSAR_CONFIG"
#   config_get "_BURSAR_CONFIG" '.bursar.window'  # returns value or empty string
#
# Precedence (latest wins):
#   1. plugin config.json (shipped defaults)
#   2. ~/.claude/settings.json
#   3. ~/.claude/settings.local.json (local overrides user)
#   4. <repo>/.claude/settings.json
#   5. <repo>/.claude/settings.local.json (local overrides project)

# Load config for a plugin, merging all five layers into a variable.
#
# Arguments:
#   $1 = plugin name (e.g., "bursar", "compass")
#   $2 = repo root (or empty for no-repo defaults)
#   $3 = output variable name (e.g., "_BURSAR_CONFIG")
#
# Sets the output variable to the merged JSON config.
config_load_plugin() {
	local plugin_name="${1:-}"
	local repo_root="${2:-}"
	local output_var="${3:-}"

	[[ -z "$plugin_name" || -z "$output_var" ]] && return 1

	local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
	local home_dir="${HOME:-}"

	# Read all five layers as raw text using $(<file) to avoid process forks.
	# Missing files degrade to empty strings (handled by jq with //).
	local default_txt="" home_txt="" home_local_txt="" repo_txt="" repo_local_txt=""
	local default_file="${plugin_root}/config.json"
	local home_file="${home_dir}/.claude/settings.json"
	local home_local_file="${home_dir}/.claude/settings.local.json"
	local repo_file=""
	local repo_local_file=""

	[[ -n "$repo_root" ]] && repo_file="${repo_root}/.claude/settings.json"
	[[ -n "$repo_root" ]] && repo_local_file="${repo_root}/.claude/settings.local.json"

	# Read each layer defensively—missing or malformed files degrade to empty.
	[[ -f "$default_file" ]] && default_txt="$(<"$default_file")"
	[[ -f "$home_file" ]] && home_txt="$(<"$home_file")"
	[[ -f "$home_local_file" ]] && home_local_txt="$(<"$home_local_file")"
	[[ -f "$repo_file" ]] && repo_txt="$(<"$repo_file")"
	[[ -f "$repo_local_file" ]] && repo_local_txt="$(<"$repo_local_file")"

	# Merge all five layers in a single jq invocation. Precedence:
	# defaults < home < home-local < repo < repo-local
	# Settings files (.json, .local.json) contribute only their plugin-scoped key.
	local merged_json
	merged_json=$(jq -n \
		--arg plugin "$plugin_name" \
		--arg d "$default_txt" \
		--arg h "$home_txt" \
		--arg hl "$home_local_txt" \
		--arg r "$repo_txt" \
		--arg rl "$repo_local_txt" \
		'
		def deepmerge($a; $b):
			if ($a|type) == "object" and ($b|type) == "object" then
				reduce (($a|keys) + ($b|keys) | unique)[] as $k
					({}; .[$k] = deepmerge($a[$k]; $b[$k]))
			elif $b == null then $a
			else $b end;

		($d | fromjson? // {}) as $defaults
		| (($h | fromjson? // {}) | {($plugin): (.[$plugin] // {})}) as $home
		| (($hl | fromjson? // {}) | {($plugin): (.[$plugin] // {})}) as $home_local
		| (($r | fromjson? // {}) | {($plugin): (.[$plugin] // {})}) as $repo
		| (($rl | fromjson? // {}) | {($plugin): (.[$plugin] // {})}) as $repo_local
		| deepmerge(
			deepmerge(
				deepmerge(
					deepmerge($defaults; $home);
					$home_local);
				$repo);
			$repo_local)
		' 2>/dev/null) || merged_json="{}"

	[[ -z "$merged_json" ]] && merged_json="{}"

	# Set the output variable in the caller's scope via printf (works in bash).
	printf -v "$output_var" '%s' "$merged_json"
	return 0
}

# Get a string value from loaded config.
#
# Arguments:
#   $1 = variable name containing the config JSON (e.g., "_BURSAR_CONFIG")
#   $2 = jq path to the value (e.g., '.bursar.window')
#
# Outputs: the string value, or empty string if not found.
config_get() {
	local config_var="${1:-}"
	local path="${2:-}"

	[[ -z "$config_var" ]] && return 1

	# Use indirect expansion to read the variable's value.
	local config_json="${!config_var}"
	# NB: do NOT use `${path} // empty` — jq's `//` treats `false` and `0` as
	# empty, so a false boolean would read back as "" and a true default would
	# silently flip it. Emit the raw value and map only a literal JSON null to
	# the empty string.
	local v
	v=$(printf '%s' "$config_json" | jq -r "${path}" 2>/dev/null) || return 1
	[[ "$v" == "null" ]] && v=""
	printf '%s' "$v"
}

# Get a JSON value from loaded config.
#
# Arguments:
#   $1 = variable name containing the config JSON (e.g., "_BURSAR_CONFIG")
#   $2 = jq path to the value (e.g., '.bursar.markers')
#
# Outputs: the JSON value, or null if not found.
config_get_json() {
	local config_var="${1:-}"
	local path="${2:-}"

	[[ -z "$config_var" ]] && return 1

	local config_json="${!config_var}"
	printf '%s' "$config_json" | jq -c "${path}" 2>/dev/null
}

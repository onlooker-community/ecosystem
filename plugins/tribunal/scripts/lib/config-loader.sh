#!/usr/bin/env bash
# Shared config loader for Onlooker plugins.
#
# Merges all five layers of settings precedence in a single jq pass, so every
# plugin resolves config the same way.
#
# This file is vendored. scripts/lib/config-loader.sh is canonical, and a
# byte-identical copy sits in every plugins/<name>/scripts/lib/. Edit the
# canonical one, then run scripts/sync-shared-libs.sh to propagate it;
# test/bats/config-lib-self-locating.bats fails on any copy that drifts.
#
# Vendoring rather than sharing one file is deliberate. Each plugin publishes
# rooted at ./plugins/<name>, so an installed plugin is its own tree with no
# ecosystem checkout above it. A path reaching up to the repo root resolves in
# the monorepo and nowhere else — installed, it defines no accessors at all and
# every caller silently reads shipped defaults (ecosystem-ber).
#
# Usage:
#   # In your plugin's config lib (e.g. plugins/bursar/scripts/lib/bursar-config.sh).
#   # Locate the loader from the sourcing file's OWN path, never from a
#   # caller-supplied $PLUGIN_ROOT: that variable is read at source time from
#   # whatever scope did the sourcing, so a sub-shell that inherits
#   # CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT loses every accessor below while
#   # still exiting 0 (ecosystem-88v, ecosystem-7bj). The loader is a sibling,
#   # so the resolved path stays inside the plugin and holds in either layout.
#   _BURSAR_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   _BURSAR_CONFIG_LOADER="${_BURSAR_CONFIG_LIB_DIR}/config-loader.sh"
#   if [[ ! -f "$_BURSAR_CONFIG_LOADER" ]]; then
#   	printf 'bursar: missing %s — plugin package is incomplete\n' \
#   		"$_BURSAR_CONFIG_LOADER" >&2
#   	exit 1
#   fi
#   # shellcheck source=plugins/bursar/scripts/lib/config-loader.sh
#   source "$_BURSAR_CONFIG_LOADER"
#   config_load_plugin "bursar" "$repo_root" "_BURSAR_CONFIG"
#   config_get "_BURSAR_CONFIG" '.bursar.window'  # returns value or empty string
#
#   The missing-file guard declines to fail soft on purpose. A vendored copy
#   that goes missing is a packaging defect, and silence is what let the two
#   prior instances of this bug run for months.
#
#   The `shellcheck source=` directive is repo-root-relative, not
#   file-relative: the linter resolves it against its own working directory,
#   and `npm run test:shellcheck` runs from the repo root. A file-relative path
#   there silently degrades to SC1091 "not following", which `-S error` hides.
#   Keep "shellcheck" off the start of a comment line while you are at it — the
#   directive parser reads one there as a directive and errors out.
#
# Precedence (latest wins):
#   1. plugin config.json (shipped defaults)
#   2. <claude_dir>/settings.json
#   3. <claude_dir>/settings.local.json (local overrides user)
#   4. <worktree>/.claude/settings.json        committed, branch-scoped
#   5. <parent>/.claude/settings.local.json    gitignored, machine-scoped
#
# Layers 4 and 5 resolve against DIFFERENT roots. settings.json is committed, so
# a worktree on a feature branch must see its own copy — the dogfooding rollout
# stages plugin enablement through exactly that file. settings.local.json is
# gitignored, so `git worktree add` never copies it and it exists only in the
# main checkout; resolving it against the worktree would silently drop every
# local override in a worktree session. See ecosystem-449.37 and ADR-004.

# Resolve the two repo-scoped roots from a session cwd.
#
# Sets, in the caller's scope:
#   _CONFIG_WORKTREE_ROOT  --show-toplevel      the tree this session is in
#   _CONFIG_PARENT_ROOT    --git-common-dir/..  the main checkout
#
# The two are the same in a normal checkout and differ in a linked worktree,
# where the parent is where a gitignored settings.local.json actually lives.
#
# Resolution lives here rather than at the call sites on purpose. Thirty-three
# callers each picking a root is how ecosystem-ber, ecosystem-68z and
# ecosystem-449.37 all happened: a wrong root is accepted silently and reads as
# "no config" rather than as an error. No caller picks one now, so none can pick
# a wrong one.
#
# Memoized on cwd. Hooks are one process per fire, so the cache cannot outlive a
# single invocation.
_config_resolve_roots() {
	local cwd="${1:-}"

	_CONFIG_WORKTREE_ROOT=""
	_CONFIG_PARENT_ROOT=""

	if [[ -z "$cwd" || ! -d "$cwd" ]]; then
		return 0
	fi

	if [[ "${_CONFIG_ROOTS_CWD:-}" == "$cwd" ]]; then
		_CONFIG_WORKTREE_ROOT="${_CONFIG_ROOTS_WORKTREE:-}"
		_CONFIG_PARENT_ROOT="${_CONFIG_ROOTS_PARENT:-}"
		return 0
	fi

	# One fork for both answers; git emits them in argument order. Two separate
	# rev-parse calls measured ~9.7ms against ~4.8ms for this, and hook cost is
	# already a live concern (ecosystem-449.29, 449.43, ff7, 6ce).
	local out=""
	out=$(git -C "$cwd" rev-parse --show-toplevel --git-common-dir 2>/dev/null) || out=""

	local toplevel="" common_dir=""
	if [[ -n "$out" ]]; then
		toplevel=$(printf '%s\n' "$out" | sed -n '1p')
		common_dir=$(printf '%s\n' "$out" | sed -n '2p')
	fi

	if [[ -n "$toplevel" ]]; then
		_CONFIG_WORKTREE_ROOT=$(cd "$toplevel" 2>/dev/null && pwd -P) \
			|| _CONFIG_WORKTREE_ROOT=""
	fi

	# --git-common-dir is relative in a normal checkout (".git" from the root,
	# "../.git" from a subdirectory) and absolute in a linked worktree. It is
	# relative to CWD, not to the toplevel — resolving it from the toplevel
	# climbs one level too far for any session started in a subdirectory.
	if [[ -n "$common_dir" ]]; then
		if [[ "$common_dir" != /* ]]; then
			common_dir=$(cd "$cwd" && cd "$common_dir" 2>/dev/null && pwd -P) \
				|| common_dir=""
		fi
		if [[ -n "$common_dir" && -d "$common_dir" ]]; then
			_CONFIG_PARENT_ROOT=$(cd "${common_dir}/.." 2>/dev/null && pwd -P) \
				|| _CONFIG_PARENT_ROOT=""
		fi
	fi

	# Outside a repo git answers nothing, but .claude/settings.json is a Claude
	# Code concept rather than a git one and a plain directory can carry one.
	# Fall back to cwd so a non-git project keeps its config. There is no upward
	# walk here: outside git there is no defined project boundary to walk to.
	if [[ -z "$_CONFIG_WORKTREE_ROOT" ]]; then
		_CONFIG_WORKTREE_ROOT="$cwd"
	fi
	if [[ -z "$_CONFIG_PARENT_ROOT" ]]; then
		_CONFIG_PARENT_ROOT="$_CONFIG_WORKTREE_ROOT"
	fi

	_CONFIG_ROOTS_CWD="$cwd"
	_CONFIG_ROOTS_WORKTREE="$_CONFIG_WORKTREE_ROOT"
	_CONFIG_ROOTS_PARENT="$_CONFIG_PARENT_ROOT"
	return 0
}

# Load config for a plugin, merging all five layers into a variable.
#
# Arguments:
#   $1 = plugin name (e.g., "bursar", "compass")
#   $2 = session cwd (or empty for no-repo defaults). NOT a repo root — the
#        loader resolves the worktree and parent roots from it itself.
#   $3 = output variable name (e.g., "_BURSAR_CONFIG")
#
# Sets the output variable to the merged JSON config.
config_load_plugin() {
	local plugin_name="${1:-}"
	local cwd="${2:-}"
	local output_var="${3:-}"

	[[ -z "$plugin_name" || -z "$output_var" ]] && return 1

	local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
	local home_dir="${HOME:-}"

	# Read all five layers as raw text using $(<file) to avoid process forks.
	# Missing files degrade to empty strings (handled by jq with //).
	local default_txt="" home_txt="" home_local_txt="" repo_txt="" repo_local_txt=""
	local default_file="${plugin_root}/config.json"
	# Resolve the user config dir the same way validate-path.sh:19 does, and in
	# the same order. This was a hardcoded "${home_dir}/.claude", but Claude Code
	# exports CLAUDE_CONFIG_DIR to hook processes and it is not always
	# $HOME/.claude — where it differs, $HOME/.claude typically does not exist at
	# all, so layers 2 and 3 of the precedence chain below were unreachable and
	# every user-level plugin override was silently ignored (ecosystem-68z).
	#
	# This lib is vendored standalone into every plugin and cannot source
	# validate-path.sh, so the chain is mirrored rather than shared. The two are
	# pinned together by test/bats/config-loader-config-dir.bats.
	local claude_dir="${CLAUDE_HOME:-${CLAUDE_CONFIG_DIR:-${home_dir}/.claude}}"
	local home_file="${claude_dir}/settings.json"
	local home_local_file="${claude_dir}/settings.local.json"
	local repo_file=""
	local repo_local_file=""

	# Layer 4 is committed and therefore branch-scoped: a worktree must see its
	# own branch's copy. Layer 5 is gitignored and therefore machine-scoped:
	# `git worktree add` never copies it, so it lives only in the parent.
	_config_resolve_roots "$cwd"
	if [[ -n "$_CONFIG_WORKTREE_ROOT" ]]; then
		repo_file="${_CONFIG_WORKTREE_ROOT}/.claude/settings.json"
	fi
	if [[ -n "$_CONFIG_PARENT_ROOT" ]]; then
		repo_local_file="${_CONFIG_PARENT_ROOT}/.claude/settings.local.json"
	fi

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

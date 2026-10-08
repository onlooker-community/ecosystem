#!/usr/bin/env bash
# cartographer-config.sh — load and query Cartographer configuration.
#
# Uses the shared config loader from ecosystem. Merges five layers in precedence order:
#   1. plugins/cartographer/config.json  (plugin defaults)
#   2. ~/.claude/settings.json           (.cartographer subtree)
#   3. ~/.claude/settings.local.json     (.cartographer subtree, local overrides user)
#   4. <worktree>/.claude/settings.json      (.cartographer subtree)
#   5. <parent>/.claude/settings.local.json (.cartographer subtree, local overrides project)
#
# Layers 4 and 5 resolve against DIFFERENT roots. settings.json is committed and
# therefore branch-scoped; settings.local.json is gitignored, so git worktree add
# never copies it and it lives only in the main checkout. config_load_plugin
# takes a session cwd and derives both roots itself (ecosystem-449.37).
#
# Usage:
#   cartographer_config_load <cwd>
#   cartographer_config_get_json ".cartographer.exclude_paths"
#   cartographer_config_int <jq-path> <default>  # non-negative integer

# Resolve the vendored loader from this file's own location. $PLUGIN_ROOT is
# whatever the sourcing scope happened to set, so a sub-shell that inherits
# CLAUDE_PLUGIN_ROOT but not PLUGIN_ROOT would lose every accessor silently.
# The loader is a sibling rather than a path up to the repo root, because an
# installed plugin is its own tree with no ecosystem checkout above it.
_CARTOGRAPHER_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CARTOGRAPHER_CONFIG_LOADER="${_CARTOGRAPHER_CONFIG_LIB_DIR}/config-loader.sh"
if [[ ! -f "$_CARTOGRAPHER_CONFIG_LOADER" ]]; then
	printf 'cartographer: missing %s — plugin package is incomplete\n' \
		"$_CARTOGRAPHER_CONFIG_LOADER" >&2
	exit 1
fi
# shellcheck source=plugins/cartographer/scripts/lib/config-loader.sh
source "$_CARTOGRAPHER_CONFIG_LOADER"

_CARTOGRAPHER_CONFIG=""

cartographer_config_load() {
	local cwd="${1:-}"
	config_load_plugin "cartographer" "$cwd" "_CARTOGRAPHER_CONFIG"
	return 0
}

cartographer_config_get() {
	local path="${1:-}"
	config_get "_CARTOGRAPHER_CONFIG" "${path}"
}

cartographer_config_get_json() {
	local path="${1:-}"
	config_get_json "_CARTOGRAPHER_CONFIG" "${path}"
}

# Read a value that is about to reach arithmetic. The fallback idioms this
# replaces catch an empty value and the literal "null" and nothing else, so any
# other non-numeric value passed through to (( )), where bash reads the bare
# word as a variable name and set -u stops the shell -- at status 0, because
# these scripts run set -uo pipefail deliberately without -e (ONL-132).
#
# config_get_int always prints a non-negative integer, falling back to $2 for
# anything failing ^[0-9]+$. Do not use it for floats (temperature, margins).
cartographer_config_int() {
	local path="$1"
	local default="$2"
	config_get_int "_CARTOGRAPHER_CONFIG" "${path}" "${default}"
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
	# Keep in step with config.json. A config that fails to load falls back here
	# SILENTLY (exit 0, accessors undefined), so a stale 60 would quietly restore
	# ecosystem-449.64: every analyzer pass measured 67-131s, so 60 killed all of
	# them, not just slow ones.
	cartographer_config_int '.cartographer.phase_timeout_seconds' 180
}

cartographer_config_total_timeout() {
	cartographer_config_int '.cartographer.total_timeout_seconds' 600
}

cartographer_config_audit_interval_hours() {
	cartographer_config_int '.cartographer.audit_interval_hours' 24
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

# ── undocumented_entity phase ──────────────────────────────────────────────────
# Disk → doc detection. Unlike the other phases these are read inside the
# analysis sub-shell rather than by the orchestrator; see run-audit.sh and
# ecosystem-88v for why.

cartographer_config_undocumented_enabled() {
	local v
	v=$(cartographer_config_get '.cartographer.undocumented_entity.enabled')
	printf '%s' "${v:-true}"
}

cartographer_config_undocumented_globs() {
	cartographer_config_get_json \
		'.cartographer.undocumented_entity.globs // ["plugins/*/","skills/*/"]'
}

cartographer_config_undocumented_exclude() {
	cartographer_config_get_json '.cartographer.undocumented_entity.exclude // []'
}

cartographer_config_undocumented_max_findings() {
	local v
	v=$(cartographer_config_get '.cartographer.undocumented_entity.max_findings')
	printf '%s' "${v:-20}"
}

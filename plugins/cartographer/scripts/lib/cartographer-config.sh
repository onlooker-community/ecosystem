#!/usr/bin/env bash
# cartographer-config.sh — load and query Cartographer configuration.
#
# Uses the shared config loader from ecosystem. Merges five layers in precedence order:
#   1. plugins/cartographer/config.json  (plugin defaults)
#   2. ~/.claude/settings.json           (.cartographer subtree)
#   3. ~/.claude/settings.local.json     (.cartographer subtree, local overrides user)
#   4. <repo>/.claude/settings.json      (.cartographer subtree)
#   5. <repo>/.claude/settings.local.json (.cartographer subtree, local overrides project)
#
# Usage:
#   cartographer_config_load <repo_root>
#   cartographer_config_get_json ".cartographer.exclude_paths"

# shellcheck source=../../../scripts/lib/config-loader.sh
source "${PLUGIN_ROOT}/../../scripts/lib/config-loader.sh"

_CARTOGRAPHER_CONFIG=""

cartographer_config_load() {
	local repo_root="${1:-}"
	config_load_plugin "cartographer" "$repo_root" "_CARTOGRAPHER_CONFIG"
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
	local v
	v=$(cartographer_config_get '.cartographer.phase_timeout_seconds')
	printf '%s' "${v:-60}"
}

cartographer_config_total_timeout() {
	local v
	v=$(cartographer_config_get '.cartographer.total_timeout_seconds')
	printf '%s' "${v:-600}"
}

cartographer_config_audit_interval_hours() {
	local v
	v=$(cartographer_config_get '.cartographer.audit_interval_hours')
	printf '%s' "${v:-24}"
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

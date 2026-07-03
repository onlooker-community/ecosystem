#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/cartographer-config.sh"
}

@test "deep merge: user-level partial override preserves plugin defaults" {
  mkdir -p "${HOME}/.claude"
  printf '%s\n' '{"cartographer":{"audit_interval_hours":12}}' > "${HOME}/.claude/settings.json"
  cartographer_config_load ""
  local interval model
  interval=$(cartographer_config_audit_interval_hours)
  model=$(cartographer_config_model_extraction)
  [ "$interval" = "12" ]
  [ "$model" = "claude-haiku-4-5-20251001" ]
}

@test "deep merge: repo overrides user but preserves user keys not in repo" {
  mkdir -p "${HOME}/.claude"
  printf '%s\n' '{"cartographer":{"audit_interval_hours":6,"phase_timeout_seconds":30}}' > "${HOME}/.claude/settings.json"
  local repo="${BATS_TEST_TMPDIR}/repo2"
  mkdir -p "${repo}/.claude"
  printf '%s\n' '{"cartographer":{"audit_interval_hours":48}}' > "${repo}/.claude/settings.json"
  cartographer_config_load "$repo"
  local interval timeout_s
  interval=$(cartographer_config_audit_interval_hours)
  timeout_s=$(cartographer_config_phase_timeout)
  [ "$interval" = "48" ]
  [ "$timeout_s" = "30" ]
}

@test "model_extraction falls back to default when not configured" {
  cartographer_config_load ""
  local v
  v=$(cartographer_config_model_extraction)
  [ "$v" = "claude-haiku-4-5-20251001" ]
}

@test "model_synthesis falls back to default when not configured" {
  cartographer_config_load ""
  local v
  v=$(cartographer_config_model_synthesis)
  [ "$v" = "claude-haiku-4-5-20251001" ]
}

@test "model_extraction respects user-level override" {
  mkdir -p "${HOME}/.claude"
  printf '%s\n' '{"cartographer":{"extraction":{"model":"claude-sonnet-4-6"}}}' > "${HOME}/.claude/settings.json"
  cartographer_config_load ""
  local v
  v=$(cartographer_config_model_extraction)
  [ "$v" = "claude-sonnet-4-6" ]
}

@test "phase_timeout_seconds defaults to 60" {
  cartographer_config_load ""
  local v
  v=$(cartographer_config_phase_timeout)
  [ "$v" = "60" ]
}

@test "audit_interval_hours defaults to 24" {
  cartographer_config_load ""
  local v
  v=$(cartographer_config_audit_interval_hours)
  [ "$v" = "24" ]
}

@test "exclude_paths defaults are non-empty JSON array" {
  cartographer_config_load ""
  local v
  v=$(cartographer_config_exclude_paths)
  # Must be a non-empty JSON array containing node_modules
  echo "$v" | jq -e 'type == "array" and length > 0' >/dev/null
  echo "$v" | jq -e 'any(. == "node_modules")' >/dev/null
}

#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/archivist-config.sh"
}

@test "injection.max_items defaults from config.json" {
  archivist_config_load ""
  local v
  v=$(archivist_config_get '.archivist.injection.max_items')
  [ "$v" = "8" ]
}

@test "settings overlay merges deeply (preserves unset defaults)" {
  mkdir -p "${HOME}/.claude"
  printf '%s\n' '{"archivist":{"injection":{"max_items":3}}}' > "${HOME}/.claude/settings.json"
  archivist_config_load ""
  local overridden default_model
  overridden=$(archivist_config_get '.archivist.injection.max_items')
  default_model=$(archivist_config_get '.archivist.extraction.model')
  [ "$overridden" = "3" ]
  [ -n "$default_model" ]
}

# ---------------------------------------------------------------------------
# archivist_config_int (ONL-132)
#
# The plain getter returns whatever is configured, so a non-numeric value that
# reaches arithmetic kills the caller at status 0. This is the getter for
# anything that does.
# ---------------------------------------------------------------------------

_set_max_commits() {
  mkdir -p "${HOME}/.claude"
  jq -n --argjson v "$1" '{archivist: {mining: {max_commits_per_run: $v}}}' > "${HOME}/.claude/settings.json"
}

@test "config_int returns the shipped value when nothing overrides it" {
  archivist_config_load ""
  [ "$(archivist_config_int '.archivist.injection.max_items' 99)" = "8" ]
}

@test "config_int returns a numeric override" {
  _set_max_commits 25
  archivist_config_load ""
  [ "$(archivist_config_int '.archivist.mining.max_commits_per_run' 10)" = "25" ]
}

@test "config_int falls back on a non-numeric override" {
  _set_max_commits '"ten"'
  archivist_config_load ""
  # The plain getter passes the typo straight through, which is the hazard.
  [ "$(archivist_config_get '.archivist.mining.max_commits_per_run')" = "ten" ] || return 1
  [ "$(archivist_config_int '.archivist.mining.max_commits_per_run' 10)" = "10" ]
}

@test "config_int falls back on a negative override" {
  _set_max_commits -3
  archivist_config_load ""
  [ "$(archivist_config_int '.archivist.mining.max_commits_per_run' 10)" = "10" ]
}

@test "config_int falls back on a path nothing sets" {
  archivist_config_load ""
  [ "$(archivist_config_int '.archivist.no_such_key' 7)" = "7" ]
}

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

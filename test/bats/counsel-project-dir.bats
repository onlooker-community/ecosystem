#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/counsel"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-project-dir.sh"
}

@test "counsel_project_dir includes project key in path" {
  local key="abc123def456"
  run counsel_project_dir "$key"
  [ "$status" -eq 0 ]
  [[ "$output" == *"counsel/${key}/briefs" ]]
}

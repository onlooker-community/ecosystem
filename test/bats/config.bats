#!/usr/bin/env bats

setup_file() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
}

@test "config.json is valid JSON with plugin_name" {
  run jq -e '.plugin_name | length > 0' "${REPO_ROOT}/config.json"
  [ "$status" -eq 0 ]
}

@test "hooks.json references existing hook script" {
  local hook_cmd
  hook_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [ -n "$hook_cmd" ]
  # Expand CLAUDE_PLUGIN_ROOT placeholder for path check
  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  # Strip surrounding quotes from hooks.json command
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "plugin.json is valid JSON" {
  run jq -e '.name and .version' "${REPO_ROOT}/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
}

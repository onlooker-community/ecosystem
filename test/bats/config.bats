#!/usr/bin/env bats

setup_file() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
}

@test "config.json is valid JSON with plugin_name" {
  run jq -e '.plugin_name | length > 0' "${REPO_ROOT}/config.json"
  [ "$status" -eq 0 ]
}

@test "hooks.json wildcard matcher references tool-sequence-tracker" {
  run jq -e '.hooks.PreToolUse[0].matcher == "*"' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *tool-sequence-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json Agent matcher references agent-spawn-tracker" {
  run jq -e '.hooks.PreToolUse[1].matcher == "Agent"' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *agent-spawn-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json Skill matcher references skill-usage-tracker" {
  run jq -e '.hooks.PreToolUse[2].matcher == "Skill"' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.PreToolUse[2].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *skill-usage-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json UserPromptExpansion references skill-usage-tracker" {
  run jq -e '.hooks.UserPromptExpansion[0].matcher == ""' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.UserPromptExpansion[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *skill-usage-tracker.sh ]]
}

@test "hooks.json PostToolUse references tool-history-tracker" {
  run jq -e '.hooks.PostToolUse[0].matcher == "*"' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *tool-history-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json PostToolUseFailure references tool-history-tracker" {
  run jq -e '.hooks.PostToolUseFailure[0].matcher == "*"' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.PostToolUseFailure[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *tool-history-tracker.sh ]]
}

@test "plugin.json is valid JSON" {
  run jq -e '.name and .version' "${REPO_ROOT}/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
}

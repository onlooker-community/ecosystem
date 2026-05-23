#!/usr/bin/env bats

setup_file() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
}

@test "config.json is valid JSON with plugin_name" {
  run jq -e '.plugin_name | length > 0' "${REPO_ROOT}/config.json"
  [ "$status" -eq 0 ]
}

@test "ecosystem plugin.json version matches package.json" {
  local pkg_ver
  pkg_ver=$(jq -r '.version' "${REPO_ROOT}/package.json")

  # Claude Code reads version from plugin.json. marketplace.json should NOT
  # carry plugins[].version (see plugins-reference: setting both is a drift
  # hazard since plugin.json silently wins).
  run jq -e --arg v "$pkg_ver" '.version == $v' "${REPO_ROOT}/.claude-plugin/plugin.json"
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

@test "hooks.json UserPromptSubmit references turn and session-duration trackers" {
  run jq -e '.hooks.UserPromptSubmit[0].hooks | length == 2' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local turn_cmd duration_cmd
  turn_cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  duration_cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[1].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$turn_cmd" == *turn-tracker.sh ]]
  [[ "$duration_cmd" == *session-duration-tracker.sh ]]

  for hook_cmd in "$turn_cmd" "$duration_cmd"; do
    local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
    script_path="${script_path//\"/}"
    run test -x "$script_path"
    [ "$status" -eq 0 ]
  done
}

@test "hooks.json SessionStart references session-start-tracker" {
  run jq -e '.hooks.SessionStart[0].matcher == "*"' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *session-start-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json PreCompact references pre-compact-tracker for manual and auto" {
  run jq -e '.hooks.PreCompact | length == 2' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.PreCompact[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *pre-compact-tracker.sh ]]

  run jq -e '.hooks.PreCompact[0].matcher == "manual" and .hooks.PreCompact[1].matcher == "auto"' \
    "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json PostCompact references context-compact-tracker for manual and auto" {
  run jq -e '.hooks.PostCompact | length == 2' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.PostCompact[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *context-compact-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json SessionEnd references session-end-tracker" {
  run jq -e '.hooks.SessionEnd[0].matcher == "*"' "${REPO_ROOT}/hooks/hooks.json"
  [ "$status" -eq 0 ]

  local hook_cmd
  hook_cmd=$(jq -r '.hooks.SessionEnd[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *session-end-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json TaskCreated references task-tracker" {
  local hook_cmd
  hook_cmd=$(jq -r '.hooks.TaskCreated[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *task-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json TaskCompleted references task-tracker" {
  local hook_cmd
  hook_cmd=$(jq -r '.hooks.TaskCompleted[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *task-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json WorktreeCreate references worktree-tracker" {
  local hook_cmd
  hook_cmd=$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *worktree-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "hooks.json WorktreeRemove references worktree-tracker" {
  local hook_cmd
  hook_cmd=$(jq -r '.hooks.WorktreeRemove[0].hooks[0].command' "${REPO_ROOT}/hooks/hooks.json")
  [[ "$hook_cmd" == *worktree-tracker.sh ]]

  local script_path="${hook_cmd//\$CLAUDE_PLUGIN_ROOT/$REPO_ROOT}"
  script_path="${script_path//\"/}"
  run test -x "$script_path"
  [ "$status" -eq 0 ]
}

@test "plugin.json is valid JSON" {
  run jq -e '.name and .version' "${REPO_ROOT}/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]
}

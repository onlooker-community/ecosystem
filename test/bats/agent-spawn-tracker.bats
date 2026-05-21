#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"
  rm -f "${ONLOOKER_DIR}/agent-spawn-trackers.json" "${ONLOOKER_DIR}/agent-spawn-trackers.json.lock"
}

@test "agent-spawn-tracker approves non-Agent tool calls" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/non-agent-tool.json"
  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/agent-spawn-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "approve" and (.reason | test("Not an Agent"))' >/dev/null
}

@test "agent-spawn-tracker approves Agent tool calls" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/agent-tool.json"
  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/agent-spawn-tracker.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "approve"' >/dev/null
}

@test "agent-spawn-tracker records session in state file" {
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/agent-tool.json"
  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/agent-spawn-tracker.sh" >/dev/null 2>&1
  jq -e '.sessions["test-session-001"] | type == "object"' "${ONLOOKER_DIR}/agent-spawn-trackers.json" >/dev/null
}

#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  # shellcheck source=../../scripts/lib/prompt-rules.sh
  source "${REPO_ROOT}/scripts/lib/prompt-rules.sh"
  export CLAUDE_PLUGIN_ROOT="${REPO_ROOT}"

  ensure_dir_exists "$ONLOOKER_PROMPT_RULES_SESSIONS_DIR"
}

write_global_rules() {
  local body="$1"
  printf '%s\n' "$body" > "$(prompt_rules_global_path)"
}

write_project_rules() {
  local project_dir="$1"
  local body="$2"
  mkdir -p "${project_dir}/.claude"
  printf '%s\n' "$body" > "${project_dir}/.claude/prompt-rules.json"
}

@test "load_merged returns empty array when no rule files exist" {
  local rules
  rules=$(prompt_rules_load_merged "$TEST_HOME")
  [ "$(echo "$rules" | jq 'length')" = "0" ]
}

@test "load_merged surfaces global rules when only global exists" {
  write_global_rules '{
    "rules": [
      {"id": "r1", "pattern": "foo", "guidance": "global rule", "enabled": true}
    ]
  }'
  local rules
  rules=$(prompt_rules_load_merged "$TEST_HOME")
  [ "$(echo "$rules" | jq 'length')" = "1" ]
  [ "$(echo "$rules" | jq -r '.[0].guidance')" = "global rule" ]
}

@test "load_merged: project overrides global by id" {
  write_global_rules '{
    "rules": [
      {"id": "r1", "pattern": "foo", "guidance": "global version"},
      {"id": "r2", "pattern": "bar", "guidance": "global only"}
    ]
  }'
  write_project_rules "$TEST_HOME" '{
    "rules": [
      {"id": "r1", "pattern": "foo", "guidance": "project version"}
    ]
  }'
  local rules
  rules=$(prompt_rules_load_merged "$TEST_HOME")
  [ "$(echo "$rules" | jq 'length')" = "2" ]
  [ "$(echo "$rules" | jq -r '.[] | select(.id=="r1") | .guidance')" = "project version" ]
  [ "$(echo "$rules" | jq -r '.[] | select(.id=="r2") | .guidance')" = "global only" ]
}

@test "load_merged filters out enabled: false rules" {
  write_global_rules '{
    "rules": [
      {"id": "r1", "pattern": "foo", "guidance": "on"},
      {"id": "r2", "pattern": "bar", "guidance": "off", "enabled": false}
    ]
  }'
  local rules
  rules=$(prompt_rules_load_merged "$TEST_HOME")
  [ "$(echo "$rules" | jq 'length')" = "1" ]
  [ "$(echo "$rules" | jq -r '.[0].id')" = "r1" ]
}

@test "pattern_matches: hit, miss, empty pattern" {
  run prompt_rules_pattern_matches "hello world" "world"
  [ "$status" -eq 0 ]
  run prompt_rules_pattern_matches "hello world" "xyz"
  [ "$status" -eq 1 ]
  run prompt_rules_pattern_matches "hello world" ""
  [ "$status" -eq 1 ]
}

@test "mark_fired + load_fired round-trip is idempotent" {
  prompt_rules_mark_fired "sess-A" "rule-1"
  prompt_rules_mark_fired "sess-A" "rule-1"
  prompt_rules_mark_fired "sess-A" "rule-2"
  local fired
  fired=$(prompt_rules_load_fired "sess-A")
  [ "$(echo "$fired" | jq 'length')" = "2" ]
  [ "$(echo "$fired" | jq -r '. | sort | join(",")')" = "rule-1,rule-2" ]
}

@test "hook injects additionalContext when prompt matches a rule" {
  write_global_rules '{
    "rules": [
      {"id": "rule-no-verify", "pattern": "--no-verify", "guidance": "Skipping hooks usually masks the real issue."}
    ]
  }'
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit-rule-match.json"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e \
    '.hookSpecificOutput.hookEventName == "UserPromptSubmit"
     and (.hookSpecificOutput.additionalContext | contains("Skipping hooks"))' >/dev/null
}

@test "hook outputs nothing when no rule matches" {
  write_global_rules '{
    "rules": [
      {"id": "rule-no-verify", "pattern": "--no-verify", "guidance": "Skipping hooks usually masks the real issue."}
    ]
  }'
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit-rule-nomatch.json"

  run bash -c "cat '${fixture}' | '${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook fires a rule once per session" {
  write_global_rules '{
    "rules": [
      {"id": "rule-no-verify", "pattern": "--no-verify", "guidance": "Skipping hooks usually masks the real issue."}
    ]
  }'
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit-rule-match.json"

  # First invocation: injects
  local first_output
  first_output=$(cat "$fixture" | "${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh" 2>/dev/null)
  echo "$first_output" | jq -e '.hookSpecificOutput.additionalContext | contains("Skipping hooks")' >/dev/null

  # Second invocation with same session: no injection
  local second_output
  second_output=$(cat "$fixture" | "${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh" 2>/dev/null)
  [ -z "$second_output" ]
}

@test "hook emits prompt_rule.matched and prompt_rule.applied to events log" {
  write_global_rules '{
    "rules": [
      {"id": "rule-no-verify", "pattern": "--no-verify", "guidance": "Skipping hooks usually masks the real issue."}
    ]
  }'
  : >"$ONLOOKER_EVENTS_LOG"
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit-rule-match.json"

  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh" >/dev/null 2>&1

  grep -q '"event_type":"prompt_rule.matched"' "$ONLOOKER_EVENTS_LOG"
  grep -q '"event_type":"prompt_rule.applied"' "$ONLOOKER_EVENTS_LOG"
  grep -q '"rule_id":"rule-no-verify"' "$ONLOOKER_EVENTS_LOG"
}

@test "hook still emits prompt_rule.matched on subsequent match but not prompt_rule.applied" {
  write_global_rules '{
    "rules": [
      {"id": "rule-no-verify", "pattern": "--no-verify", "guidance": "msg"}
    ]
  }'
  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit-rule-match.json"

  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh" >/dev/null 2>&1
  : >"$ONLOOKER_EVENTS_LOG"
  cat "$fixture" | "${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh" >/dev/null 2>&1

  grep -q '"event_type":"prompt_rule.matched"' "$ONLOOKER_EVENTS_LOG"
  ! grep -q '"event_type":"prompt_rule.applied"' "$ONLOOKER_EVENTS_LOG"
}

@test "hook respects per_turn_max_chars: drops overflowing rules" {
  write_global_rules '{
    "rules": [
      {"id": "r1", "pattern": "no-verify", "guidance": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
      {"id": "r2", "pattern": "no-verify", "guidance": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}
    ]
  }'
  # Use a temp plugin root with a tiny char budget
  local tmp_root="${BATS_TEST_TMPDIR}/tiny-budget-root"
  mkdir -p "$tmp_root"
  printf '%s\n' '{"plugin_name":"onlooker","prompt_rules":{"enabled":true,"per_turn_max_chars":120}}' > "$tmp_root/config.json"

  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit-rule-match.json"
  local output
  output=$(CLAUDE_PLUGIN_ROOT="$tmp_root" cat "$fixture" | CLAUDE_PLUGIN_ROOT="$tmp_root" "${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh" 2>/dev/null)

  # First rule fits (~98 chars); second pushes past 120, gets dropped.
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext | contains("AAAA") and (contains("BBBB") | not)' >/dev/null
}

@test "hook short-circuits when prompt_rules.enabled = false" {
  write_global_rules '{
    "rules": [
      {"id": "r1", "pattern": "no-verify", "guidance": "should not fire"}
    ]
  }'
  local tmp_root="${BATS_TEST_TMPDIR}/disabled-root"
  mkdir -p "$tmp_root"
  printf '%s\n' '{"plugin_name":"onlooker","prompt_rules":{"enabled":false}}' > "$tmp_root/config.json"

  local fixture="${REPO_ROOT}/test/fixtures/hook-inputs/user-prompt-submit-rule-match.json"
  local output
  output=$(CLAUDE_PLUGIN_ROOT="$tmp_root" "${REPO_ROOT}/scripts/hooks/prompt-rule-injector.sh" < "$fixture" 2>/dev/null)
  [ -z "$output" ]
}

@test "list_table reports active rules and per-session fire status" {
  write_global_rules '{
    "rules": [
      {"id": "r1", "pattern": "foo", "guidance": "global one"},
      {"id": "r2", "pattern": "bar", "guidance": "global two"}
    ]
  }'
  prompt_rules_mark_fired "session-list" "r1"

  local out
  out=$(prompt_rules_list_table "session-list" "$TEST_HOME")
  echo "$out" | grep -q "active rules: 2"
  echo "$out" | grep -q "id: r1"
  echo "$out" | grep -q "id: r2"
  # r1 is fired, r2 is not
  echo "$out" | grep -A2 "id: r1" | grep -q "fired: yes"
  echo "$out" | grep -A2 "id: r2" | grep -q "fired: no"
}

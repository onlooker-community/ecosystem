#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
  HOOK="${PLUGIN_ROOT}/scripts/hooks/lineage-post-tool-use.sh"

  source "${PLUGIN_ROOT}/scripts/lib/lineage-project-key.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git
  printf 'one\n' > "${PROJECT_REPO}/tracked.txt"
  git -C "$PROJECT_REPO" add tracked.txt
  git -C "$PROJECT_REPO" commit -qm "seed"

  PROJECT_KEY=$(lineage_project_key "$PROJECT_REPO")
  LEDGER="${ONLOOKER_DIR}/lineage/${PROJECT_KEY}/changes.jsonl"
}

_bash_input() {
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-shell" --arg cmd "$1" \
    '{cwd: $cwd, session_id: $sid, tool_name: "Bash",
      tool_input: {command: $cmd}, hook_event_name: "PostToolUse"}'
}

_run_hook() { printf '%s' "$(_bash_input "$1")" | bash "$HOOK"; }

@test "first Bash call seeds a baseline and records nothing" {
  run bash -c "printf '%s' '$(_bash_input "echo hi")' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "$LEDGER" ]
}

@test "a shell edit to a tracked file is recorded" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  _run_hook "cat >> tracked.txt <<EOF"
  [ -f "$LEDGER" ] || return 1
  run jq -r 'select(.tool == "Bash") | .file_path' "$LEDGER"
  [[ "$output" == *"tracked.txt"* ]]
}

@test "the record is tagged shell_edit and authored" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  _run_hook "cat >> tracked.txt <<EOF"
  run jq -r 'select(.tool == "Bash") | "\(.operation) \(.provenance_kind)"' "$LEDGER"
  [ "$output" = "shell_edit authored" ]
}

@test "a git switch is tagged tool_generated" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  _run_hook "git switch -c other"
  run jq -r 'select(.tool == "Bash") | .provenance_kind' "$LEDGER"
  [ "$output" = "tool_generated" ]
}

@test "a Bash call that changes nothing records nothing" {
  _run_hook "echo seed"
  _run_hook "ls -la"
  [ ! -f "$LEDGER" ]
}

@test "the baseline lives under lineage-baselines, not lineage" {
  _run_hook "echo seed"
  [ -f "${ONLOOKER_DIR}/lineage-baselines/${PROJECT_KEY}/sess-shell.json" ] || return 1
  [ ! -d "${ONLOOKER_DIR}/lineage/${PROJECT_KEY}/sess-shell.json" ]
}

@test "lockfiles are ignored" {
  _run_hook "echo seed"
  printf '{}\n' > "${PROJECT_REPO}/package-lock.json"
  git -C "$PROJECT_REPO" add package-lock.json
  git -C "$PROJECT_REPO" commit -qm "add lock"
  printf '{"a":1}\n' > "${PROJECT_REPO}/package-lock.json"
  _run_hook "npm ci"
  if [ -f "$LEDGER" ]; then
    run jq -r 'select(.tool == "Bash") | .file_path' "$LEDGER"
    [[ "$output" != *"package-lock.json"* ]]
  fi
}

@test "a non-git cwd exits 0 and records nothing" {
  outside="${BATS_TEST_TMPDIR}/nogit"
  mkdir -p "$outside"
  input=$(jq -cn --arg cwd "$outside" --arg sid "s2" \
    '{cwd: $cwd, session_id: $sid, tool_name: "Bash",
      tool_input: {command: "echo hi"}, hook_event_name: "PostToolUse"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "Edit still records exactly as before" {
  input=$(jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-shell" \
    --arg fp "${PROJECT_REPO}/tracked.txt" \
    '{cwd: $cwd, session_id: $sid, tool_name: "Edit",
      tool_input: {file_path: $fp, old_string: "one", new_string: "hello"},
      hook_event_name: "PostToolUse"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1
  run jq -r 'select(.tool == "Edit") | "\(.operation) \(has("provenance_kind"))"' "$LEDGER"
  [ "$output" = "edit false" ]
}

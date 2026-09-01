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
  source "${PLUGIN_ROOT}/scripts/lib/lineage-record.sh"
  source "${PLUGIN_ROOT}/scripts/lib/lineage-baseline.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  # Force git's own default rather than inheriting the developer machine's
  # global config, which some dev boxes set to "all" — masking the untracked-
  # directory collapse lineage_candidate_paths guards against.
  git -C "$PROJECT_REPO" config status.showUntrackedFiles normal
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git
  printf 'one\n' > "${PROJECT_REPO}/tracked.txt"
  git -C "$PROJECT_REPO" add tracked.txt
  git -C "$PROJECT_REPO" commit -qm "seed"

  PROJECT_KEY=$(lineage_project_key "$PROJECT_REPO")
  LEDGER="${ONLOOKER_DIR}/lineage/${PROJECT_KEY}/changes.jsonl"
  # The baseline is keyed by a cheap scope id (a hash of the repo root), not
  # the project key — resolving the project key is part of the setup the
  # Bash pre-gate is built to skip (ecosystem-449.13 task 4.5). Hash the
  # realpath-resolved root the hook itself derives, since PROJECT_REPO can
  # differ from it under a symlinked tmpdir (e.g. macOS /var -> /private/var).
  SCOPE_ID=$(lineage_baseline_scope_id "$(lineage_project_repo_root "$PROJECT_REPO")")
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

# Before this fix, the baseline read → decide → rebuild cycle was unlocked:
# every concurrent hook read the same not-yet-advanced baseline, independently
# decided the same pending change was new, and appended its own record.
# lineage_append's internal lock keeps any single write from corrupting the
# ledger, but cannot stop that many well-formed duplicate records from landing
# (ecosystem-449.13 I3). Four concurrent hooks against one pending change must
# produce exactly one ledger record.
@test "concurrent Bash hooks against one pending change record it exactly once (I3)" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"

  local input pids=()
  input="$(_bash_input "cat >> tracked.txt <<EOF")"
  for _ in 1 2 3 4; do
    bash -c "printf '%s' '$input' | '$HOOK'" &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  [ -f "$LEDGER" ] || return 1
  run jq -rs '[ .[] | select(.tool == "Bash") ] | length' "$LEDGER"
  [ "$output" = "1" ]
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
  [ -f "${ONLOOKER_DIR}/lineage-baselines/${SCOPE_ID}/sess-shell.json" ] || return 1
  [ ! -d "${ONLOOKER_DIR}/lineage/${SCOPE_ID}/sess-shell.json" ]
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

@test "a shell deletion is recorded, not dropped" {
  printf 'one\ntwo\n' > "${PROJECT_REPO}/tracked.txt"
  git -C "$PROJECT_REPO" add tracked.txt
  git -C "$PROJECT_REPO" commit -qm "two lines"
  _run_hook "echo seed"
  printf 'one\n' > "${PROJECT_REPO}/tracked.txt"
  _run_hook "sed -i '2d' tracked.txt"
  [ -f "$LEDGER" ] || return 1
  run jq -r 'select(.tool == "Bash") | "\(.lines_added) \(.lines_removed)"' "$LEDGER"
  [ "$output" = "0 1" ]
}

@test "a shell deletion is tagged shell_edit and authored" {
  printf 'one\ntwo\n' > "${PROJECT_REPO}/tracked.txt"
  git -C "$PROJECT_REPO" add tracked.txt
  git -C "$PROJECT_REPO" commit -qm "two lines"
  _run_hook "echo seed"
  printf 'one\n' > "${PROJECT_REPO}/tracked.txt"
  _run_hook "sed -i '2d' tracked.txt"
  run jq -r 'select(.tool == "Bash") | "\(.operation) \(.provenance_kind)"' "$LEDGER"
  [ "$output" = "shell_edit authored" ]
}

@test "a shell edit that adds and removes lines records both counts" {
  printf 'one\ntwo\n' > "${PROJECT_REPO}/tracked.txt"
  git -C "$PROJECT_REPO" add tracked.txt
  git -C "$PROJECT_REPO" commit -qm "two lines"
  _run_hook "echo seed"
  printf 'one\nthree\n' > "${PROJECT_REPO}/tracked.txt"
  _run_hook "sed -i '2s/two/three/' tracked.txt"
  [ -f "$LEDGER" ] || return 1
  run jq -r 'select(.tool == "Bash") | "\(.lines_added) \(.lines_removed)"' "$LEDGER"
  [ "$output" = "1 1" ]
}

@test "a no-change Bash call resolves no project key" {
  _run_hook "echo seed"
  run bash -c "printf '%s' '$(_bash_input "ls -la")' | LINEAGE_TRACE_SETUP=1 '$HOOK' 2>&1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" != *"SETUP_DONE"* ]]
}

@test "a changing Bash call does resolve the project key" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"
  run bash -c "printf '%s' '$(_bash_input "cat >> tracked.txt <<EOF")' | LINEAGE_TRACE_SETUP=1 '$HOOK' 2>&1"
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *"SETUP_DONE"* ]]
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

# Before this fix, the Edit path never advanced the Bash baseline, so the
# next Bash call — even a no-op like `ls` — saw the Edit's file as changed
# and appended a SECOND record with tool="Bash". lineage_match_line's
# newest-wins lookup then returned that wrong Bash record instead of the
# real Edit that introduced the line.
@test "an Edit advances the baseline so a later no-op Bash call does not re-record it" {
  _run_hook "echo seed"

  # Mirror what the real Edit tool would have done on disk before the hook
  # observes it — the hook's Edit path builds its record from tool_input
  # alone and never reads the file, so without this the baseline comparison
  # below would trivially see no diff regardless of whether the fix works.
  printf 'hello\n' > "${PROJECT_REPO}/tracked.txt"
  input=$(jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-shell" \
    --arg fp "${PROJECT_REPO}/tracked.txt" \
    '{cwd: $cwd, session_id: $sid, tool_name: "Edit",
      tool_input: {file_path: $fp, old_string: "one", new_string: "hello"},
      hook_event_name: "PostToolUse"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  _run_hook "ls -la"

  # Matched by suffix, not exact equality: the Edit path records tool_input's
  # file_path literally, while the Bash path builds its own from a
  # realpath-resolved REPO_ROOT, so the two can legitimately differ in a
  # symlinked tmpdir (e.g. macOS /var -> /private/var) despite naming the
  # same on-disk file. tracked.txt is the only file this fixture touches, so
  # the suffix is unambiguous.
  [ -f "$LEDGER" ] || return 1
  run jq -rs '[ .[] | select(.file_path | endswith("/tracked.txt")) ] | length' "$LEDGER"
  [ "$output" = "1" ] || return 1

  run jq -r 'select(.file_path | endswith("/tracked.txt")) | .tool' "$LEDGER"
  [ "$output" = "Edit" ]
}

# --- abandoned baseline locks (ecosystem-am1) ------------------------------
#
# The read → decide → rebuild lock is released by a script-level EXIT trap,
# which bash does not fire on SIGKILL or a hard harness timeout. One killed
# hook used to leave the lock behind and turn the rest of the session into a
# provenance blackout that also cost 5s per shell call — exits 0, records
# nothing, emits nothing. Exactly the failure family ecosystem-449.13 exists
# to eliminate, reached through the mechanism added to fix it.

_baseline_lock_dir() {
  printf '%s.lock.d' "$(lineage_baseline_path "$SCOPE_ID" "sess-shell")"
}

_seed_baseline_lock() {
  local holder_pid="$1" dir
  dir=$(_baseline_lock_dir)
  mkdir -p "$dir"
  printf '%s\n' "$holder_pid" >"${dir}/holder"
}

@test "a baseline lock leaked by a killed hook does not black out later recording" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"

  # A pid that is certainly gone — the signature of a SIGKILLed hook.
  sleep 0 & local dead=$!; wait "$dead" 2>/dev/null || true
  _seed_baseline_lock "$dead"

  _run_hook "cat >> tracked.txt <<EOF"
  [ -f "$LEDGER" ] || { echo "no ledger — the leaked lock blacked out recording"; return 1; }
  run jq -r 'select(.tool == "Bash") | .file_path' "$LEDGER"
  [[ "$output" == *"tracked.txt"* ]]
}

@test "a baseline lock that cannot be acquired is reported instead of swallowed" {
  _run_hook "echo seed"
  printf 'two\n' >> "${PROJECT_REPO}/tracked.txt"

  # A live holder is never broken, so this acquire genuinely fails.
  sleep 10 & local live=$!
  _seed_baseline_lock "$live"

  _run_hook "cat >> tracked.txt <<EOF"

  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  rm -rf "$(_baseline_lock_dir)"

  run jq -sr '[.[] | select(.hook == "lineage-post-tool-use" and .status == "failure")] | length' \
    "${ONLOOKER_DIR}/logs/hook-health.jsonl"
  [ "$output" -ge 1 ] || { echo "lock timeout left no trace in hook-health"; return 1; }
  run jq -sr '[.[] | select(.hook == "lineage-post-tool-use" and .status == "failure") | .error] | join(",")' \
    "${ONLOOKER_DIR}/logs/hook-health.jsonl"
  [[ "$output" == *"lock"* ]]
}

# --- one file, one path spelling (ecosystem-htl) ---------------------------
#
# The Edit path records tool_input.file_path exactly as the harness supplied
# it; the Bash path builds "$REPO_ROOT/$REL" from a realpath-resolved root.
# Under a symlinked working tree — macOS /var -> /private/var, which every
# temp-dir test hits, and any checkout living under a symlink — the same file
# lands in the ledger under two different absolute strings, so /lineage <file>
# returns half its history depending on which spelling is asked for.

@test "a file touched by both Edit and Bash lands under one path string" {
  # A symlinked root is the condition under test, so assert we actually have
  # one rather than passing vacuously on a checkout where the two agree.
  local resolved
  resolved=$(cd "$PROJECT_REPO" && pwd -P)
  [ "$resolved" != "$PROJECT_REPO" ] || skip "tmpdir is not symlinked here"

  _run_hook "echo seed"

  printf 'hello\n' > "${PROJECT_REPO}/tracked.txt"
  local input
  input=$(jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-shell" \
    --arg fp "${PROJECT_REPO}/tracked.txt" \
    '{cwd: $cwd, session_id: $sid, tool_name: "Edit",
      tool_input: {file_path: $fp, old_string: "one", new_string: "hello"},
      hook_event_name: "PostToolUse"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  printf 'again\n' >> "${PROJECT_REPO}/tracked.txt"
  _run_hook "cat >> tracked.txt <<EOF"

  # Both tools must be represented, or the assertion below is vacuous.
  run jq -sr '[.[] | .tool] | sort | unique | join(",")' "$LEDGER"
  [ "$output" = "Bash,Edit" ] || { echo "expected both tools, got: $output"; return 1; }

  run jq -sr '[.[] | .file_path] | unique | length' "$LEDGER"
  [ "$output" = "1" ]
}

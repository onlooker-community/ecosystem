#!/usr/bin/env bats
#
# Exercises the substrate-level memory.recalled emitter. The hook fires
# on SessionStart and emits one canonical memory.recalled event per
# typed memory file in the project's typed memory store at
# ~/.claude/projects/<encoded>/memory/.
#
# Curator's usage tracker depends on this signal; without it,
# zero-recall findings can't be generated. The tests below pin both the
# happy path (correct count and provenance) and the skip cases (no git
# context, no memory store, compact source).

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/memory-recall-test.git

  # Derive the encoded project dir under CLAUDE_HOME so the hook resolves
  # via the path-encoding fallback (CLAUDE_PROJECT_ENCODED unset).
  ABS_CWD=$(cd "$PROJECT_REPO" && pwd -P)
  ENCODED=$(printf '%s' "$ABS_CWD" | sed -E 's#/#-#g')
  MEM_DIR="${TEST_HOME}/.claude/projects/${ENCODED}/memory"
  mkdir -p "$MEM_DIR"

  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
  HOOK="${REPO_ROOT}/scripts/hooks/memory-recall-tracker.sh"
}

_input() {
  local source="${1:-startup}"
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-mem-test" --arg source "$source" \
    '{cwd:$cwd, session_id:$sid, source:$source, hook_event_name:"SessionStart"}'
}

_seed_memory() {
  local fname="$1" type="$2" name="${3:-$fname}"
  printf -- '---\nname: %s\ndescription: test\ntype: %s\n---\n\nBody.\n' \
    "$name" "$type" > "${MEM_DIR}/${fname}"
}

@test "memory-recall emits one event per typed memory file" {
  _seed_memory "user_role.md" "user"
  _seed_memory "feedback_no_summaries.md" "feedback"
  _seed_memory "project_auth_rewrite.md" "project"
  _seed_memory "reference_dashboards.md" "reference"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  local count
  count=$(grep -c '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG")
  [ "$count" -eq 4 ]

  # One event per memory_type, with the right filename.
  grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.memory_type == "user" and .payload.memory_file == "user_role.md")' >/dev/null
  grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.memory_type == "feedback")' >/dev/null
  grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.memory_type == "project")' >/dev/null
  grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.memory_type == "reference")' >/dev/null

  # recall_position values are 0..N-1, distinct.
  local positions
  positions=$(grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -r '.payload.recall_position' | sort -n | paste -sd, -)
  [ "$positions" = "0,1,2,3" ]
}

@test "memory-recall skips MEMORY.md itself" {
  _seed_memory "feedback_one.md" "feedback"
  printf '%s\n' '- [One](feedback_one.md) — one' > "${MEM_DIR}/MEMORY.md"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  # MEMORY.md is not its own memory; should NOT appear as a memory_file.
  ! grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.memory_file == "MEMORY.md")' >/dev/null
  local count
  count=$(grep -c '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG")
  [ "$count" -eq 1 ]
}

@test "memory-recall skips memories without a recognized type" {
  _seed_memory "feedback_valid.md" "feedback"
  # Memory with an unrecognized type field — should be silently dropped.
  printf -- '---\nname: weird\ntype: unknown\n---\n\nBody.\n' \
    > "${MEM_DIR}/weird.md"
  # Memory with no frontmatter at all — also dropped.
  printf '%s\n' 'just a body, no metadata' > "${MEM_DIR}/raw.md"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  local count
  count=$(grep -c '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG")
  [ "$count" -eq 1 ]
  grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.memory_file == "feedback_valid.md"' >/dev/null
}

@test "memory-recall emits nothing when the memory store is empty" {
  # MEM_DIR exists (created in setup) but contains no *.md files. The
  # hook walks the glob, finds zero matches, and emits no events.
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$ONLOOKER_EVENTS_LOG" ] || ! grep -q '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG"
}

@test "memory-recall emits nothing when the memory store directory does not exist" {
  # This is the genuinely-missing-directory branch — the dir check at
  # the top of the hook short-circuits before any file walk.
  rm -rf "$MEM_DIR"
  [ ! -d "$MEM_DIR" ]

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$ONLOOKER_EVENTS_LOG" ] || ! grep -q '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG"
}

@test "memory-recall is a no-op when cwd is not a git repo" {
  local non_git="${BATS_TEST_TMPDIR}/no-git"
  mkdir -p "$non_git"
  _seed_memory "user_x.md" "user"

  local input
  input=$(jq -cn --arg cwd "$non_git" --arg sid "s" --arg source "startup" \
    '{cwd:$cwd, session_id:$sid, source:$source}')

  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$ONLOOKER_EVENTS_LOG" ] || ! grep -q '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG"
}

@test "memory-recall skips compact source to avoid double-counting" {
  _seed_memory "user_x.md" "user"

  run bash -c "printf '%s' '$(_input compact)' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ ! -f "$ONLOOKER_EVENTS_LOG" ] || ! grep -q '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG"
}

@test "memory-recall payload carries the same project_key for two clones" {
  _seed_memory "user_x.md" "user"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  local key
  key=$(grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -r '.payload.project_key' | head -1)

  # Second clone of the same remote at a different path. The key should
  # match (SHA256 of remote URL, path-independent).
  local clone2="${BATS_TEST_TMPDIR}/clone2"
  mkdir -p "$clone2"
  git -C "$clone2" init -q
  git -C "$clone2" remote add origin git@github.com:org/memory-recall-test.git

  local ABS_CWD2 ENCODED2 MEM_DIR2
  ABS_CWD2=$(cd "$clone2" && pwd -P)
  ENCODED2=$(printf '%s' "$ABS_CWD2" | sed -E 's#/#-#g')
  MEM_DIR2="${TEST_HOME}/.claude/projects/${ENCODED2}/memory"
  mkdir -p "$MEM_DIR2"
  printf -- '---\nname: x\ntype: user\n---\n\nBody.\n' > "${MEM_DIR2}/user_x.md"

  rm -f "$ONLOOKER_EVENTS_LOG"
  local input2
  input2=$(jq -cn --arg cwd "$clone2" --arg sid "s" --arg source "startup" \
    '{cwd:$cwd, session_id:$sid, source:$source}')
  run bash -c "printf '%s' '$input2' | '$HOOK'"
  [ "$status" -eq 0 ]

  local key2
  key2=$(grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -r '.payload.project_key' | head -1)

  [ "$key" = "$key2" ]
}

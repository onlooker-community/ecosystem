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
  ENCODED=$(printf '%s' "$ABS_CWD" | sed -E 's#[/.]#-#g')
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
  # `|| return 1`: a non-final `!` does not fail the test (SC2314,
  # ecosystem-o09).
  ! grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.memory_file == "MEMORY.md")' >/dev/null || return 1
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
  ENCODED2=$(printf '%s' "$ABS_CWD2" | sed -E 's#[/.]#-#g')
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

# ecosystem-449.12. Claude Code encodes the project path by replacing BOTH
# path separators and dots with `-`; the fallback encoder replaced only
# slashes. Verified against real directories: none of the entries under
# $CLAUDE_CONFIG_DIR/projects contains a literal dot, and every github.com
# path renders as github-com.
#
# The consequence is a silent no-op. For any repo cloned under a
# github.com-style path -- essentially all of them -- the hook computed a
# directory that cannot exist, hit `! -d`, and exited 0 reporting success.
#
# The pre-existing tests could not catch this: they use a dot-free temp path
# AND re-derive the expected directory with the same sed the hook uses, so the
# expectation moves with the bug.
@test "a project path containing a dot resolves to the dot-replaced memory dir" {
  local dotted="${BATS_TEST_TMPDIR}/github.com/org/repo"
  mkdir -p "$dotted"
  git -C "$dotted" init -q
  git -C "$dotted" config user.email t@example.com
  git -C "$dotted" config user.name "Test"
  git -C "$dotted" remote add origin git@github.com:org/dotted.git

  local abs encoded memdir
  abs=$(cd "$dotted" && pwd -P)
  # Deliberately NOT the hook's encoder: dots become dashes too.
  encoded=$(printf '%s' "$abs" | sed -E 's#[/.]#-#g')
  memdir="${CLAUDE_HOME}/projects/${encoded}/memory"
  mkdir -p "$memdir"

  cat > "${memdir}/dotted-note.md" <<-'MEM'
	---
	name: dotted-note
	description: a memory under a path containing a dot
	metadata:
	  type: project
	---

	body
	MEM

  local input
  input=$(jq -cn --arg cwd "$dotted" --arg sid "sess-dotted" \
    '{cwd:$cwd, session_id:$sid, source:"startup", hook_event_name:"SessionStart"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  # The encoded name must carry no literal dot, and the hook must have found
  # the memory rather than silently exiting on a missing directory.
  [[ "$encoded" != *.* ]] || return 1
  grep -q '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG"
}

# The real memory format nests type under metadata:, indented. Confirmed
# against actual files written by Claude Code, e.g.
#
#   ---
#   name: authors-own-claude-marketplace
#   description: "..."
#   metadata:
#     node_type: memory
#     type: user
#   ---
#
# The extractor anchored on `^type:` at line start, so it matched the format
# these tests happened to seed and nothing Claude Code actually writes. Every
# real memory scored an empty type and was skipped by the `case` below it --
# a second silent no-op stacked on the path bug (ecosystem-449.12).
@test "a memory with type nested under metadata is recalled" {
  printf -- '---\nname: nested\ndescription: "quoted desc"\nmetadata:\n  node_type: memory\n  type: user\n  modified: 2026-08-08T15:58:14.732Z\n---\n\nBody.\n' \
    > "${MEM_DIR}/nested.md"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1
  grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.memory_type == "user" and .payload.memory_file == "nested.md")' >/dev/null
}

# node_type sits directly above type in real frontmatter. A loosened pattern
# must not mistake it for the type field.
@test "node_type is not mistaken for type" {
  printf -- '---\nname: nodetype-only\nmetadata:\n  node_type: memory\n---\n\nBody.\n' \
    > "${MEM_DIR}/nodetype-only.md"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1
  # No valid type, so no event for this file.
  ! grep '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null \
    | jq -e 'select(.payload.memory_file == "nodetype-only.md")' >/dev/null
}

# Wraps the real node so a test can count how many processes the hook starts.
_shim_node() {
  local real_node shim_dir
  real_node=$(command -v node)
  shim_dir="${BATS_TEST_TMPDIR}/shim"
  NODE_CALLS="${BATS_TEST_TMPDIR}/node-calls"
  mkdir -p "$shim_dir"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' \
    "$NODE_CALLS" "$real_node" > "${shim_dir}/node"
  chmod +x "${shim_dir}/node"
  export PATH="${shim_dir}:${PATH}"
}

# One node process per memory is what made this hook cost 66ms a file: 2445ms
# at 37 memories, on every SessionStart (ONL-113).
@test "the emitter starts once however many memories there are" {
  local i
  for i in 1 2 3 4 5 6 7 8; do
    _seed_memory "project_${i}.md" "project"
  done
  _shim_node

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  [ "$(grep -c '"event_type":"memory.recalled"' "$ONLOOKER_EVENTS_LOG")" -eq 8 ]
  [ "$(grep -c 'onlooker-event.mjs' "$NODE_CALLS")" -eq 1 ]
}

@test "recall_position counts emitted memories, not files walked" {
  _seed_memory "a.md" "project"
  printf -- '---\nname: untyped\n---\n\nBody.\n' > "${MEM_DIR}/b.md"
  _seed_memory "c with space.md" "feedback"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  run jq -rs 'map(select(.event_type == "memory.recalled"))
    | map("\(.payload.recall_position) \(.payload.memory_file)") | join(",")' \
    "$ONLOOKER_EVENTS_LOG"
  [ "$output" = "0 a.md,1 c with space.md" ]
}

@test "every recalled event carries the project envelope" {
  _seed_memory "a.md" "project"
  _seed_memory "b.md" "user"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  run jq -rs 'map(select(.event_type == "memory.recalled"))
    | map(select(.project == .payload.project_key and .project_basis == "remote")) | length' \
    "$ONLOOKER_EVENTS_LOG"
  [ "$output" = "2" ]
}

@test "the first type in frontmatter wins and the body is never read" {
  printf -- '---\nname: x\ntype: "user"\ntype: project\n---\n\ntype: reference\n' \
    > "${MEM_DIR}/first.md"
  printf -- 'no frontmatter\ntype: user\n' > "${MEM_DIR}/plain.md"
  printf -- '---\nname: x\n---\n\ntype: user\n' > "${MEM_DIR}/body-only.md"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  run jq -rs 'map(select(.event_type == "memory.recalled"))
    | map("\(.payload.memory_file)=\(.payload.memory_type)") | join(",")' \
    "$ONLOOKER_EVENTS_LOG"
  [ "$output" = "first.md=user" ]
}

@test "emit-batch drops a bad line without losing its neighbors" {
  local good bad
  good='{"plugin":"onlooker","session_id":"s","event_type":"memory.recalled","payload":{"project_key":"abcdefabcdef","memory_file":"a.md","memory_type":"user","recall_position":0}}'
  bad='{"plugin":"onlooker","session_id":"s","event_type":"memory.recalled","payload":{"memory_type":"nonsense"}}'

  run --separate-stderr bash -c "printf '%s\n%s\nnot json\n\n%s\n' '$good' '$bad' '$good' \
    | ONLOOKER_VALIDATE=1 ONLOOKER_TEST_REPORT_DIR='${BATS_TEST_TMPDIR}/report' \
      node '${REPO_ROOT}/scripts/lib/onlooker-event.mjs' emit-batch"

  [ "$status" -eq 1 ] || return 1
  [ "$(printf '%s\n' "$output" | grep -c '"event_type":"memory.recalled"')" -eq 2 ]
  printf '%s\n' "$output" | jq -es 'map(.sequence) | .[0] < .[1]' >/dev/null
}

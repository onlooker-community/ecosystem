#!/usr/bin/env bats
#
# historian enforces its own retention_days (ONL-45).
#
# The knob shipped at 365 and nothing read it, so historian kept transcripts
# forever while its config said otherwise. run-index.sh now deletes this
# project's session files older than the window, by mtime, on every pass —
# including passes that skip indexing, since the store ages whether or not
# this session had anything worth keeping.
#
# Retrieval already ignores chunks past retrieval.max_age_days (180), so a
# file past 365 was unreachable to retrieval anyway. lineage's prompt-context
# join is the one reader that loses something, and it falls back to the
# Claude Code transcript.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/historian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/historian-retention.git

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
  PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  SESSIONS="${ONLOOKER_DIR}/historian/${PROJECT_KEY}/sessions"
  OTHER_SESSIONS="${ONLOOKER_DIR}/historian/0123456789ab/sessions"
  mkdir -p "$SESSIONS" "$OTHER_SESSIONS"

  RUNNER="${PLUGIN_ROOT}/scripts/run-index.sh"
}

_age_days() {
  local path="$1" days="$2"
  python3 -c "import os,sys,time; p=sys.argv[1]; d=float(sys.argv[2]); t=time.time()-d*86400; os.utime(p,(t,t))" "$path" "$days"
}

# A session file of the given age, in the given sessions directory.
_seed() {
  local dir="$1" name="$2" days="$3"
  printf '{"chunk_id":"x","session_id":"%s"}\n' "$name" > "${dir}/${name}.jsonl"
  _age_days "${dir}/${name}.jsonl" "$days"
}

_settings() {
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' "$1" > "${PROJECT_REPO}/.claude/settings.json"
}

# No transcript, so indexing skips with transcript_path_absent. Retention
# must still run: that is the common path for a session with nothing to index.
_run_index() {
  run env \
    HISTORIAN_SESSION_ID="sess-retention" \
    HISTORIAN_CWD="$PROJECT_REPO" \
    HISTORIAN_TRANSCRIPT="" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    ONLOOKER_DIR="$ONLOOKER_DIR" \
    "$RUNNER"
}

@test "the shipped 365-day window deletes an older session file and keeps a recent one" {
  _seed "$SESSIONS" ancient 400
  _seed "$SESSIONS" recent 10

  _run_index
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${SESSIONS}/ancient.jsonl" ] || return 1
  [ -f "${SESSIONS}/recent.jsonl" ]
}

@test "a project override of retention_days is the window that applies" {
  _settings '{"historian":{"indexing":{"retention_days":30}}}'
  _seed "$SESSIONS" past 40
  _seed "$SESSIONS" inside 20

  _run_index
  [ ! -f "${SESSIONS}/past.jsonl" ] || return 1
  [ -f "${SESSIONS}/inside.jsonl" ]
}

@test "retention_days 0 keeps every session file" {
  _settings '{"historian":{"indexing":{"retention_days":0}}}'
  _seed "$SESSIONS" ancient 4000

  _run_index
  [ -f "${SESSIONS}/ancient.jsonl" ]
}

# config_get_int falls back to the default for anything that is not a
# non-negative integer. Falling back to 0 days would delete the whole store.
@test "a non-numeric retention_days falls back to 365, not to deleting everything" {
  _settings '{"historian":{"indexing":{"retention_days":"forever"}}}'
  _seed "$SESSIONS" month_old 40
  _seed "$SESSIONS" ancient 400

  _run_index
  [ -f "${SESSIONS}/month_old.jsonl" ] || return 1
  [ ! -f "${SESSIONS}/ancient.jsonl" ]
}

# retention_days resolves per project, so one project's window must not
# reach another project's store.
@test "retention only touches this project's sessions" {
  _settings '{"historian":{"indexing":{"retention_days":30}}}'
  _seed "$OTHER_SESSIONS" elsewhere 40

  _run_index
  [ -f "${OTHER_SESSIONS}/elsewhere.jsonl" ]
}

@test "only session transcripts are deleted, not other files in the directory" {
  _seed "$SESSIONS" ancient 400
  printf 'x' > "${SESSIONS}/notes.txt"
  _age_days "${SESSIONS}/notes.txt" 400

  _run_index
  [ ! -f "${SESSIONS}/ancient.jsonl" ] || return 1
  [ -f "${SESSIONS}/notes.txt" ]
}

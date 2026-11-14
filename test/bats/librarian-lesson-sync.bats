#!/usr/bin/env bats
#
# The approved-but-unsynced reminder, and the opt-in background sync.
#
# Lessons reach approved/ unattended (lesson_auto), and nothing told anyone
# they stay on this machine until `onlooker sync` runs. SessionStart now says
# so on every session until they are synced, and with lesson_sync.auto on it
# starts the sync itself, detached, at most once per min_interval_minutes.
#
# "Synced" is what the CLI recorded in $ONLOOKER_DIR/pushed.json: a lesson id
# present there was confirmed held by the pool. An edited lesson keeps its id,
# so it reads as synced until the next sync, the same limit `onlooker status`
# accepts.

bats_require_minimum_version 1.5.0

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO/.claude"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-sync.git

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
  PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-start.sh"

  # A stand-in CLI that records each invocation. Its name is unique so the
  # real `onlooker` on a developer's PATH can never be the one that runs.
  SYNC_CALLS="${BATS_TEST_TMPDIR}/sync-calls"
  : > "$SYNC_CALLS"
  export SYNC_CALLS
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  cat > "${STUB_BIN}/onlooker-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYNC_CALLS"
STUB
  chmod +x "${STUB_BIN}/onlooker-stub"
  export PATH="${STUB_BIN}:${PATH}"

  _settings '{"cli": "onlooker-stub"}'
}

# Usage: _settings <lesson_sync_json>
_settings() {
  jq -cn --argjson s "$1" '{librarian: {lesson_sync: $s}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
}

_input() {
  jq -cn --arg cwd "$PROJECT_REPO" '{cwd: $cwd, source: "startup", session_id: "sess-sync"}'
}

# Usage: _approve <lesson_id> [project_key]
_approve() {
  local dir="${ONLOOKER_DIR}/librarian/${2:-$PROJECT_KEY}/lessons/approved"
  mkdir -p "$dir"
  jq -cn --arg id "$1" '{id: $id, visibility: "org", claim: "c"}' > "${dir}/$1.json"
}

# Usage: _pushed <lesson_id>...
_pushed() {
  mkdir -p "$ONLOOKER_DIR"
  jq -cn '{apiBaseUrl: "https://api.example", lessons: ($ARGS.positional | map({(.): "d"}) | add // {})}' \
    --args "$@" > "${ONLOOKER_DIR}/pushed.json"
}

_link() {
  mkdir -p "$ONLOOKER_DIR"
  printf '%s\n' '{"machineToken": "tok"}' > "${ONLOOKER_DIR}/cli.json"
}

_context() {
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1
  CONTEXT=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')
}

# Polls for the detached sync's side effect, never for the process.
_await_sync_calls() {
  local want="$1" i n=0
  for ((i = 0; i < 100; i++)); do
    n=$(grep -c . "$SYNC_CALLS" 2>/dev/null || true)
    [ "${n:-0}" -ge "$want" ] && return 0
    sleep 0.1
  done
  echo "wanted ${want} sync call(s), saw ${n:-0}" >&2
  return 1
}

_calls() { grep -c . "$SYNC_CALLS" 2>/dev/null || true; }

@test "no approved lessons, no sync line" {
  _link
  _context || return 1
  [[ "$CONTEXT" != *"not synced"* ]]
}

@test "an approved lesson missing from pushed.json is surfaced as unsynced" {
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA; _pushed
  _context || return 1
  [[ "$CONTEXT" == *'1 approved lesson(s) not synced — run `onlooker-stub sync`'* ]]
}

@test "approved lessons the pool already holds are not surfaced" {
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA; _pushed 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  [[ "$CONTEXT" != *"not synced"* ]]
}

@test "with no pushed.json every approved lesson is unsynced, across every project" {
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA; _approve 01LESSONBBBBBBBBBBBBBBBBBB aaaaaaaaaaaa
  _context || return 1
  [[ "$CONTEXT" == *"2 approved lesson(s) not synced"* ]]
}

@test "an unreadable pushed.json counts every approved lesson as unsynced" {
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA
  printf 'not json' > "${ONLOOKER_DIR}/pushed.json"
  _context || return 1
  [[ "$CONTEXT" == *"1 approved lesson(s) not synced"* ]]
}

@test "an unlinked machine is told to link first" {
  _approve 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  [[ "$CONTEXT" == *'not synced — run `onlooker-stub link`, then `onlooker-stub sync`'* ]]
}

@test "a machine without the CLI is told to install it" {
  _settings '{"cli": "onlooker-not-installed"}'
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  [[ "$CONTEXT" == *"not synced — install the onlooker CLI"* ]]
}

@test "the reminder is surfaced with every other queue empty" {
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  [ "$CONTEXT" = '1 approved lesson(s) not synced — run `onlooker-stub sync`' ]
}

@test "remind false silences the line" {
  _settings '{"cli": "onlooker-stub", "remind": false}'
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  [[ "$CONTEXT" != *"not synced"* ]]
}

@test "without auto, SessionStart never runs the CLI" {
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  sleep 0.5
  [ "$(_calls)" = "0" ]
}

@test "with auto on, SessionStart starts one background sync and says so" {
  _settings '{"cli": "onlooker-stub", "auto": true}'
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  [[ "$CONTEXT" == *"1 approved lesson(s) not synced — syncing in the background"* ]] || return 1
  _await_sync_calls 1 || return 1
  [ "$(cat "$SYNC_CALLS")" = "sync" ]
}

@test "a second session inside the interval starts no second sync, and says the last one did not land" {
  _settings '{"cli": "onlooker-stub", "auto": true, "min_interval_minutes": 60}'
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  _await_sync_calls 1 || return 1
  _context || return 1
  [[ "$CONTEXT" == *'still not synced after a background sync — run `onlooker-stub sync` to see why'* ]] || return 1
  sleep 0.5
  [ "$(_calls)" = "1" ]
}

@test "auto never starts a sync on an unlinked machine" {
  _settings '{"cli": "onlooker-stub", "auto": true}'
  _approve 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  [[ "$CONTEXT" == *"run \`onlooker-stub link\`"* ]] || return 1
  sleep 0.5
  [ "$(_calls)" = "0" ]
}

@test "auto starts nothing when everything is synced" {
  _settings '{"cli": "onlooker-stub", "auto": true}'
  _link; _approve 01LESSONAAAAAAAAAAAAAAAAAA; _pushed 01LESSONAAAAAAAAAAAAAAAAAA
  _context || return 1
  sleep 0.5
  [ "$(_calls)" = "0" ]
}

@test "the shipped config reminds and does not sync on its own" {
  run jq -c '.librarian.lesson_sync' "${PLUGIN_ROOT}/config.json"
  [ "$output" = '{"remind":true,"auto":false,"min_interval_minutes":60,"cli":"onlooker"}' ]
}

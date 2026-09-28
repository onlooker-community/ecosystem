#!/usr/bin/env bats
#
# historian's SessionEnd hook must not block session shutdown on indexing.
#
# ONL-123. historian-session-end.sh states its own contract in its header —
# "Always exits 0. Never blocks session shutdown." — and then ran the whole
# pipeline inline, which it could not finish. A SessionEnd hook that declares
# no timeout is killed at 1500ms, and the work does not fit in that:
#
#   - A warm embed of one chunk measured 51ms, so the budget buys about 29
#     chunks. A real 8.5MB transcript chunks into 117.
#   - A cold model load measured 11.24s, against a configured 8s request
#     timeout, so it could never complete either way.
#
# Both failures were invisible. Every historian.indexing.complete with
# outcome "ok" in the live log had indexed exactly 2 chunks — not historian
# working, just the only size that fit — while the larger sessions appear in
# hook-health.jsonl as `terminated` at 1503-1527ms.
#
# The pipeline now lives in run-index.sh and the hook only launches it. What
# these tests pin is that the launch stays a launch: the moment someone waits
# on the child, the 1500ms ceiling is back and the failure is silent again.

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/historian-test.git

  # A copy of the plugin, so run-index.sh can be replaced with a stub that
  # takes a known, long time. The hook resolves the runner from its own
  # location, so redirecting it means moving the hook too.
  PLUGIN_ROOT="${BATS_TEST_TMPDIR}/historian"
  cp -R "${REPO_ROOT}/plugins/historian" "$PLUGIN_ROOT"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  HOOK="${PLUGIN_ROOT}/scripts/hooks/historian-session-end.sh"

  STARTED_MARKER="${BATS_TEST_TMPDIR}/indexer_started"
  FINISHED_MARKER="${BATS_TEST_TMPDIR}/indexer_finished"

  TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
  jq -cn '{type:"user", message:{content:"a turn worth indexing"}}' >"$TRANSCRIPT"

  SESSION_ID="sess-nonblocking"
}

# The indexer outlives the hook, which means it also outlives the test. Left
# alone its writes race bats removing the tree underneath it. Waiting for the
# stub to finish is the same wait scribe-nonblocking-stop.bats does on its
# lock.
teardown() {
  local waited=0
  while [[ "$waited" -lt 15 ]]; do
    [[ -f "$FINISHED_MARKER" ]] && break
    [[ ! -f "$STARTED_MARKER" ]] && break
    sleep 1
    waited=$((waited + 1))
  done
}

_install_slow_indexer() {
  local sleep_s="${1:-5}"
  cat >"${PLUGIN_ROOT}/scripts/run-index.sh" <<STUB
#!/usr/bin/env bash
printf 'x' > "${STARTED_MARKER}"
sleep ${sleep_s}
printf 'x' > "${FINISHED_MARKER}"
exit 0
STUB
  chmod +x "${PLUGIN_ROOT}/scripts/run-index.sh"
}

_input() {
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "$SESSION_ID" \
    --arg transcript "$TRANSCRIPT" \
    '{cwd:$cwd, session_id:$sid, transcript_path:$transcript, hook_event_name:"SessionEnd"}'
}

_elapsed_ms() {
  local start="$1" end="$2"
  printf '%s' "$((end - start))"
}

_now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

@test "the hook returns without waiting for indexing to finish" {
  _install_slow_indexer 5

  local start end elapsed
  start=$(_now_ms)
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  end=$(_now_ms)
  elapsed=$(_elapsed_ms "$start" "$end")

  [ "$status" -eq 0 ] || return 1

  # The indexer sleeps 5s. Anything close to that means the hook waited, which
  # is the regression this file exists to catch. The real ceiling is the
  # 1500ms SessionEnd deadline; 2500ms leaves room for a loaded CI box without
  # letting a genuine wait through.
  [ "$elapsed" -lt 2500 ] || {
    printf 'hook took %sms; it waited for the indexer\n' "$elapsed" >&2
    return 1
  }
}

@test "the launched indexer actually runs" {
  _install_slow_indexer 1

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  # Detached, so it starts shortly after the hook returns rather than during.
  local waited=0
  while [[ "$waited" -lt 10 ]]; do
    [[ -f "$STARTED_MARKER" ]] && break
    sleep 1
    waited=$((waited + 1))
  done

  [ -f "$STARTED_MARKER" ]
}

@test "a payload with no session id launches nothing" {
  _install_slow_indexer 1

  local input
  input=$(jq -cn --arg cwd "$PROJECT_REPO" \
    '{cwd:$cwd, hook_event_name:"SessionEnd"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  # Nothing to attribute an event to, so there is nothing for the child to
  # report either. Give a launch time to show up before concluding it didn't.
  sleep 2
  [ ! -f "$STARTED_MARKER" ]
}

@test "the hook still exits 0 when the indexer is missing entirely" {
  rm -f "${PLUGIN_ROOT}/scripts/run-index.sh"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "indexer stderr lands in a log rather than being discarded" {
  cat >"${PLUGIN_ROOT}/scripts/run-index.sh" <<STUB
#!/usr/bin/env bash
printf 'x' > "${STARTED_MARKER}"
printf 'historian: deliberate diagnostic\n' >&2
printf 'x' > "${FINISHED_MARKER}"
exit 0
STUB
  chmod +x "${PLUGIN_ROOT}/scripts/run-index.sh"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  local log="${ONLOOKER_DIR}/historian/index.log"
  local waited=0
  while [[ "$waited" -lt 10 ]]; do
    [[ -f "$FINISHED_MARKER" ]] && break
    sleep 1
    waited=$((waited + 1))
  done

  # scribe lost a --max-tokens bug to a discarded stderr and produced nothing
  # across 13,201 sessions without anyone noticing (ONL-30). Detaching the
  # work moves every remaining diagnostic off the terminal, so the one place
  # it can still be read has to be this file.
  [ -f "$log" ] || return 1
  grep -q "deliberate diagnostic" "$log"
}

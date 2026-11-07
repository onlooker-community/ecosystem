#!/usr/bin/env bats
#
# The scheduled storage sweep (ONL-44).
#
# scripts/onlooker-store-prune.mjs only ran when someone remembered to run it,
# and nobody had since August. storage-gc.sh runs it from SessionEnd at most
# once per interval_hours. The prune itself is detached: a dry run alone took
# 1.9s on the real store, past SessionEnd's 1500ms ceiling for a plugin hook.
#
# The positive cases wait for the detached run's report instead of asserting
# on the call. The negative cases assert on the stamp, which the hook touches
# synchronously and only when it launches a run, so "nothing ran" is a fact
# about the hook's return rather than an absence that might still change.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  load_validate_path
  export CLAUDE_PLUGIN_ROOT="$REPO_ROOT"
  HOOK="${REPO_ROOT}/scripts/hooks/storage-gc.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q

  GC_DIR="${ONLOOKER_DIR}/storage-gc"
  STAMP="${GC_DIR}/last-run"
  REPORT="${GC_DIR}/last-run.json"
  LOCK="${GC_DIR}/run.lock"
  mkdir -p "${ONLOOKER_DIR}/session-trackers" "${ONLOOKER_DIR}/session-history"
}

_age_minutes() {
  local path="$1" minutes="$2"
  python3 -c "import os,sys,time; p=sys.argv[1]; m=float(sys.argv[2]); t=time.time()-m*60; os.utime(p,(t,t))" "$path" "$minutes"
}

_age_days() { _age_minutes "$1" "$(($2 * 1440))"; }

_mtime() { python3 -c "import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))" "$1"; }

_input() {
  jq -cn --arg cwd "$PROJECT_REPO" '{cwd: $cwd, session_id: "sess-gc", hook_event_name: "SessionEnd", reason: "exit"}'
}

_run_hook() {
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
}

# The detached prune writes its report last. Poll for it rather than sleeping
# a fixed time, so a slow CI runner waits longer instead of failing.
_await_report() {
  local i
  for i in $(seq 1 100); do
    [[ -f "$REPORT" ]] && return 0
    sleep 0.1
  done
  echo "no report at ${REPORT} after 10s" >&2
  return 1
}

_seed_old_tracker() {
  printf '{"turn_number":1}' > "${ONLOOKER_DIR}/session-trackers/old"
  _age_days "${ONLOOKER_DIR}/session-trackers/old" 5
  printf '{"turn_number":1}' > "${ONLOOKER_DIR}/session-trackers/live"
}

@test "storage-gc is registered on SessionEnd" {
  jq -e '.hooks.SessionEnd[].hooks[].command | select(test("storage-gc.sh"))' \
    "${REPO_ROOT}/hooks/hooks.json" >/dev/null
}

@test "with no stamp, the sweep runs and prunes past the window but not the live tracker" {
  _seed_old_tracker

  _run_hook
  [ "$status" -eq 0 ] || return 1
  _await_report || return 1

  [ ! -f "${ONLOOKER_DIR}/session-trackers/old" ] || return 1
  [ -f "${ONLOOKER_DIR}/session-trackers/live" ] || return 1
  jq -e '.totals.deleted >= 1 and .dryRun == false' "$REPORT" >/dev/null
}

@test "a stamp older than interval_hours runs the sweep again" {
  mkdir -p "$GC_DIR"
  : > "$STAMP"
  _age_minutes "$STAMP" $((25 * 60))
  _seed_old_tracker

  _run_hook
  _await_report || return 1
  [ ! -f "${ONLOOKER_DIR}/session-trackers/old" ]
}

@test "a fresh stamp exits without launching a run" {
  mkdir -p "$GC_DIR"
  : > "$STAMP"
  _age_minutes "$STAMP" 60
  local before
  before=$(_mtime "$STAMP")

  _run_hook
  [ "$status" -eq 0 ] || return 1
  [ "$(_mtime "$STAMP")" -eq "$before" ] || return 1
  [ ! -d "$LOCK" ]
}

@test "a run already in flight is not joined by a second one" {
  mkdir -p "$LOCK"

  _run_hook
  [ "$status" -eq 0 ] || return 1
  [ ! -f "$STAMP" ] || return 1
  [ -d "$LOCK" ]
}

# A run killed outright (SIGKILL, a reboot) never removes its lock. Without a
# reclaim the sweep would stop for good, silently, the first time that happened.
@test "a lock left by a run that died over an hour ago is reclaimed" {
  mkdir -p "$LOCK"
  _age_minutes "$LOCK" 90
  _seed_old_tracker

  _run_hook
  _await_report || return 1
  [ ! -f "${ONLOOKER_DIR}/session-trackers/old" ]
}

@test "storage_gc.enabled false launches nothing" {
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"storage_gc":{"enabled":false}}' > "${PROJECT_REPO}/.claude/settings.json"

  _run_hook
  [ "$status" -eq 0 ] || return 1
  [ ! -f "$STAMP" ]
}

@test "the configured retention window is the one the prune applies" {
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"storage_gc":{"retention_days":30}}' > "${PROJECT_REPO}/.claude/settings.json"
  printf '{}' > "${ONLOOKER_DIR}/session-history/past.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/past.jsonl" 40
  printf '{}' > "${ONLOOKER_DIR}/session-history/inside.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/inside.jsonl" 20

  _run_hook
  _await_report || return 1
  [ ! -f "${ONLOOKER_DIR}/session-history/past.jsonl" ] || return 1
  [ -f "${ONLOOKER_DIR}/session-history/inside.jsonl" ]
}

@test "a non-numeric retention_days falls back to 90, not to deleting everything" {
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"storage_gc":{"retention_days":"never"}}' > "${PROJECT_REPO}/.claude/settings.json"
  printf '{}' > "${ONLOOKER_DIR}/session-history/month_old.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/month_old.jsonl" 40

  _run_hook
  _await_report || return 1
  [ -f "${ONLOOKER_DIR}/session-history/month_old.jsonl" ]
}

@test "the hook reports to hook-health" {
  _run_hook
  [ "$status" -eq 0 ] || return 1
  jq -e -s 'map(select(.hook == "storage-gc" and .status == "success")) | length == 1' \
    "${ONLOOKER_DIR}/logs/hook-health.jsonl" >/dev/null
}

# Plugins must not create ~/.onlooker for a user who never set it up.
@test "an absent store is left absent" {
  rm -rf "$ONLOOKER_DIR"

  _run_hook
  [ "$status" -eq 0 ] || return 1
  [ ! -d "$GC_DIR" ]
}

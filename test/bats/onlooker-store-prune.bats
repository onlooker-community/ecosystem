#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PRUNE="${REPO_ROOT}/scripts/onlooker-store-prune.mjs"
  mkdir -p "${ONLOOKER_DIR}/session-trackers" \
           "${ONLOOKER_DIR}/session-history" \
           "${ONLOOKER_DIR}/scribe/sessions" \
           "${ONLOOKER_DIR}/historian/abc123/sessions" \
           "${ONLOOKER_DIR}/lineage/abc123" \
           "${ONLOOKER_DIR}/lineage-baselines/abc123" \
           "${ONLOOKER_DIR}/logs"
}

# Age a file by setting its mtime N days into the past.
_age_days() {
  local path="$1" days="$2"
  python3 -c "import os,sys,time; p=sys.argv[1]; d=float(sys.argv[2]); t=time.time()-d*86400; os.utime(p,(t,t))" "$path" "$days"
}

@test "prunes scratch trackers older than the window" {
  printf '{"turn_number":1}' > "${ONLOOKER_DIR}/session-trackers/old"
  printf '{"turn_number":1}' > "${ONLOOKER_DIR}/session-trackers/fresh"
  _age_days "${ONLOOKER_DIR}/session-trackers/old" 5

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/session-trackers/old" ] || return 1
  [ -f "${ONLOOKER_DIR}/session-trackers/fresh" ]
}

@test "keeps analysis files inside the retention window" {
  printf '{}' > "${ONLOOKER_DIR}/session-history/recent.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/recent.jsonl" 30

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ -f "${ONLOOKER_DIR}/session-history/recent.jsonl" ]
}

@test "prunes analysis files past the retention window" {
  printf '{}' > "${ONLOOKER_DIR}/session-history/ancient.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/ancient.jsonl" 120

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/session-history/ancient.jsonl" ]
}

@test "deletes a payload-free scribe file but keeps one with a prompt" {
  printf '{"session_id":"a","captured_prompt":null,"captured_at":null}' \
    > "${ONLOOKER_DIR}/scribe/sessions/empty.json"
  printf '{"session_id":"b","captured_prompt":"real work","captured_at":"2026-08-01T00:00:00Z"}' \
    > "${ONLOOKER_DIR}/scribe/sessions/full.json"

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/scribe/sessions/empty.json" ] || return 1
  [ -f "${ONLOOKER_DIR}/scribe/sessions/full.json" ]
}

@test "prunes stale lineage baselines but keeps fresh ones" {
  printf '{}' > "${ONLOOKER_DIR}/lineage-baselines/abc123/old.json"
  printf '{}' > "${ONLOOKER_DIR}/lineage-baselines/abc123/fresh.json"
  _age_days "${ONLOOKER_DIR}/lineage-baselines/abc123/old.json" 5

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/lineage-baselines/abc123/old.json" ] || return 1
  [ -f "${ONLOOKER_DIR}/lineage-baselines/abc123/fresh.json" ]
}

@test "never touches durable stores or logs" {
  printf '{}' > "${ONLOOKER_DIR}/historian/abc123/sessions/old.jsonl"
  printf '{}' > "${ONLOOKER_DIR}/lineage/abc123/changes.jsonl"
  printf '{}' > "${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
  _age_days "${ONLOOKER_DIR}/historian/abc123/sessions/old.jsonl" 400
  _age_days "${ONLOOKER_DIR}/lineage/abc123/changes.jsonl" 400
  _age_days "${ONLOOKER_DIR}/logs/onlooker-events.jsonl" 400

  run node "$PRUNE" --dir "$ONLOOKER_DIR"
  [ "$status" -eq 0 ] || return 1
  [ -f "${ONLOOKER_DIR}/historian/abc123/sessions/old.jsonl" ] || return 1
  [ -f "${ONLOOKER_DIR}/lineage/abc123/changes.jsonl" ] || return 1
  [ -f "${ONLOOKER_DIR}/logs/onlooker-events.jsonl" ]
}

@test "dry run deletes nothing but reports what it would delete" {
  printf '{}' > "${ONLOOKER_DIR}/session-trackers/old"
  _age_days "${ONLOOKER_DIR}/session-trackers/old" 5

  run node "$PRUNE" --dir "$ONLOOKER_DIR" --dry-run --json
  [ "$status" -eq 0 ] || return 1
  [ -f "${ONLOOKER_DIR}/session-trackers/old" ] || return 1
  printf '%s' "$output" | jq -e '.dryRun == true and .totals.deleted == 1' >/dev/null
}

@test "exits cleanly when the store does not exist" {
  run node "$PRUNE" --dir "${BATS_TEST_TMPDIR}/nope"
  [ "$status" -eq 0 ]
}

@test "honors a custom retention window" {
  printf '{}' > "${ONLOOKER_DIR}/session-history/midlife.jsonl"
  _age_days "${ONLOOKER_DIR}/session-history/midlife.jsonl" 40

  run node "$PRUNE" --dir "$ONLOOKER_DIR" --retention-days 30
  [ "$status" -eq 0 ] || return 1
  [ ! -f "${ONLOOKER_DIR}/session-history/midlife.jsonl" ]
}

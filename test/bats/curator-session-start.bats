#!/usr/bin/env bats
#
# Exercises the curator SessionStart hook end-to-end against a synthetic
# typed memory store. Verifies the four cheap-tier finding kinds, dedup
# on repeated scans, and the SessionStart surfacer's pointer rendering.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/curator"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO/scripts"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/curator-test.git

  # Seed a real file that the path-broken check should NOT flag.
  printf 'live\n' > "${PROJECT_REPO}/scripts/live.py"

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/curator-project-key.sh"
  PROJECT_KEY=$(curator_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  CURATOR_DIR="${ONLOOKER_DIR}/curator/${PROJECT_KEY}"
  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

  # Memory store at a predictable path. Bypass the ${CLAUDE_PROJECT_ENCODED}
  # template by overriding memory_store_path to an absolute path in the
  # project settings file.
  MEM_DIR="${TEST_HOME}/.claude/projects/test-project/memory"
  mkdir -p "$MEM_DIR" "${PROJECT_REPO}/.claude"
  jq -n --arg path "$MEM_DIR" \
    '{
      curator: {
        enabled: true,
        memory_store_path: $path,
        date_check: { date_grace_period_days: 7 }
      }
    }' > "${PROJECT_REPO}/.claude/settings.json"

  HOOK="${PLUGIN_ROOT}/scripts/hooks/curator-session-start.sh"
}

_input() {
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-curator-test" \
    '{cwd: $cwd, source: "startup", session_id: $sid}'
}

_seed_memory() {
  local name="$1" type="$2" body="$3"
  local file="${MEM_DIR}/${name}"
  printf -- '---\nname: %s\ndescription: test\ntype: %s\n---\n\n%s\n' \
    "$name" "$type" "$body" > "$file"
}

_write_index() {
  local entries="$1"   # newline-separated `- [Title](file.md) — hook` lines
  printf '%b\n' "$entries" > "${MEM_DIR}/MEMORY.md"
}

@test "session-start no-ops when curator is disabled" {
  rm -f "${PROJECT_REPO}/.claude/settings.json"
  _seed_memory "feedback_stale.md" "feedback" "Decayed 2025-01-01 reference."

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
  [ ! -f "$ONLOOKER_EVENTS_LOG" ] || ! grep -q 'curator' "$ONLOOKER_EVENTS_LOG"
}

@test "session-start emits scan events with empty memory store" {
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null

  grep -q '"event_type":"curator.scan.started"' "$ONLOOKER_EVENTS_LOG"
  grep '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.findings_new == 0 and .payload.outcome == "ok"' >/dev/null
}

@test "session-start flags a date past the grace period" {
  _seed_memory "project_freeze.md" "project" \
    "Merge freeze begins 2026-03-05 for mobile release cut."
  _write_index '- [Freeze](project_freeze.md) — merge freeze date'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  grep '"event_type":"curator.finding.date_decayed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.memory_file == "project_freeze.md" and
             .payload.matched_phrase == "2026-03-05" and
             .payload.days_past > 7' >/dev/null

  # Finding persisted on disk.
  ls "${CURATOR_DIR}/findings"/*.json | grep -q '\.json$'

  # Surfacer rendered the pointer.
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Curator: 1 open finding"* ]]
  [[ "$ctx" == *"date-decayed"* ]]
  [[ "$ctx" == *"/curator review"* ]]
}

@test "session-start flags a broken path reference" {
  _seed_memory "reference_legacy.md" "reference" \
    "See scripts/legacy_ingest.py for the old pipeline shape."
  _write_index '- [Legacy](reference_legacy.md) — old pipeline'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  grep '"event_type":"curator.finding.path_broken"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.memory_file == "reference_legacy.md" and
             .payload.broken_path == "scripts/legacy_ingest.py"' >/dev/null

  # Live file (scripts/live.py) does NOT produce a finding.
  ! grep '"event_type":"curator.finding.path_broken"' "$ONLOOKER_EVENTS_LOG" \
    | grep -q 'live.py' || false
}

@test "session-start flags MEMORY.md pointing at a missing file" {
  _write_index '- [Ghost](feedback_ghost.md) — never existed'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  grep '"event_type":"curator.finding.broken_index"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.referenced_file == "feedback_ghost.md"' >/dev/null
}

@test "session-start flags orphaned memory file" {
  # File on disk, no MEMORY.md reference.
  _seed_memory "user_orphan.md" "user" "Some orphaned context."

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  grep '"event_type":"curator.finding.orphaned_memory"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.memory_file == "user_orphan.md"' >/dev/null
}

@test "session-start dedupes findings on repeated scans" {
  _seed_memory "project_freeze.md" "project" "Date 2025-01-01 in the past."
  _write_index '- [Freeze](project_freeze.md) — old date'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local first_count
  first_count=$(ls "${CURATOR_DIR}/findings"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$first_count" -ge 1 ]

  # Second scan — the same finding should not produce a new file.
  rm -f "$ONLOOKER_EVENTS_LOG"
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local second_count
  second_count=$(ls "${CURATOR_DIR}/findings"/*.json 2>/dev/null | wc -l | tr -d ' ')
  [ "$second_count" -eq "$first_count" ]

  # scan.complete reports findings_new == 0 on the dedup'd pass.
  grep '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.findings_new == 0' >/dev/null
}

@test "surfacer pluralizes finding count" {
  _seed_memory "project_a.md" "project" "Date 2025-01-01"
  _seed_memory "project_b.md" "project" "Date 2024-06-30"
  _write_index "$(printf '%s\n%s' \
    '- [A](project_a.md) — a' \
    '- [B](project_b.md) — b')"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"2 open findings"* ]]
}

@test "MEMORY.md path-traversal entries are recorded as broken_index, never read" {
  # Seed a sentinel file outside the memory dir that the parser must
  # NEVER touch. The escape attempt below points at a path that would
  # resolve to this file if filename sanitization were missing.
  local outside_dir="${TEST_HOME}/.claude/projects"
  local sentinel="${outside_dir}/sentinel.txt"
  printf 'untouched\n' > "$sentinel"
  local sentinel_mtime_before
  sentinel_mtime_before=$(stat -f %m "$sentinel" 2>/dev/null || stat -c %Y "$sentinel")

  # MEMORY.md tries to escape with `../sentinel.txt` and an absolute path.
  _write_index "$(printf '%s\n%s\n%s' \
    '- [Escape](../sentinel.txt) — traversal attempt' \
    '- [Abs](/tmp/curator-abs-attempt.md) — absolute path attempt' \
    '- [Normal](real.md) — clean reference')"
  _seed_memory "real.md" "project" "Normal body."

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  # Both unsafe entries surface as broken_index findings.
  grep '"event_type":"curator.finding.broken_index"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.referenced_file == "../sentinel.txt")' >/dev/null
  grep '"event_type":"curator.finding.broken_index"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.referenced_file == "/tmp/curator-abs-attempt.md")' >/dev/null

  # The clean reference resolves as expected (no broken_index for it).
  ! grep '"event_type":"curator.finding.broken_index"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.referenced_file == "real.md")' >/dev/null

  # The sentinel file wasn't read (mtime unchanged) and content intact.
  local sentinel_mtime_after
  sentinel_mtime_after=$(stat -f %m "$sentinel" 2>/dev/null || stat -c %Y "$sentinel")
  [ "$sentinel_mtime_before" = "$sentinel_mtime_after" ]
  grep -q 'untouched' "$sentinel"
}

@test "path_broken does not fire on URLs or absolute paths in memory bodies" {
  _seed_memory "reference_urls.md" "reference" "$(cat <<'BODY'
See https://example.com/foo.py for upstream context.
Also /usr/bin/python3.11 is the system python on macOS.
But scripts/legacy_ingest.py is the broken in-repo path.
BODY
)"
  _write_index '- [Refs](reference_urls.md) — mixed refs'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  # The in-repo broken path still fires.
  grep '"event_type":"curator.finding.path_broken"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.broken_path == "scripts/legacy_ingest.py")' >/dev/null

  # Neither the URL host nor the absolute path produce a finding.
  ! grep '"event_type":"curator.finding.path_broken"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.broken_path | contains("example.com"))' >/dev/null
  ! grep '"event_type":"curator.finding.path_broken"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.broken_path | contains("python3.11"))' >/dev/null
}

@test "surfacer counts multiple same-kind findings correctly" {
  # Two date_decayed findings: with the group_by-without-sort bug, the
  # summary would render as "1 date-decayed, 1 date-decayed" because
  # ULID-ordered findings can interleave kinds. The sort_by(.kind) fix
  # makes the summary aggregate correctly to "2 date-decayed".
  _seed_memory "project_a.md" "project" "Stale date 2025-01-01"
  _seed_memory "project_b.md" "project" "Older date 2024-06-30"
  _write_index "$(printf '%s\n%s' \
    '- [A](project_a.md) — a' \
    '- [B](project_b.md) — b')"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"2 date-decayed"* ]]
  # The buggy output would have looked like "1 date-decayed, 1 date-decayed".
  [[ "$ctx" != *"1 date-decayed, 1 date-decayed"* ]]
}

@test "cheap_checks.enabled=false skips the scan and emits skip_reason disabled" {
  printf '%s\n' \
    '{"curator":{"enabled":true,"memory_store_path":"'"$MEM_DIR"'","cheap_checks":{"enabled":false}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  _seed_memory "project_stale.md" "project" "Decayed 2025-01-01"
  _write_index '- [S](project_stale.md) — s'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  # scan.complete uses skip_reason: disabled.
  grep '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "skipped" and .payload.skip_reason == "disabled"' >/dev/null

  # No findings were written, even though the date would have matched.
  [ ! -d "${CURATOR_DIR}/findings" ] || [ -z "$(ls -A "${CURATOR_DIR}/findings" 2>/dev/null)" ]

  # No per-finding events emitted.
  ! grep -q '"event_type":"curator.finding.date_decayed"' "$ONLOOKER_EVENTS_LOG"
}

@test "surfacer truncates context past max_pointer_chars" {
  printf '%s\n' \
    '{"curator":{"enabled":true,"memory_store_path":"'"$MEM_DIR"'","surfacer":{"max_pointer_chars":40}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  _seed_memory "project_a.md" "project" "Date 2025-01-01"
  _seed_memory "project_b.md" "project" "Date 2024-06-30"
  _write_index "$(printf '%s\n%s' \
    '- [A](project_a.md) — a' \
    '- [B](project_b.md) — b')"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx ctx_len
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  # Grapheme-aware length so the trailing "…" doesn't confuse a
  # byte-counting bash check.
  ctx_len=$(python3 -c 'import sys; print(len(sys.argv[1]))' "$ctx")
  [ "$ctx_len" -le 40 ]
  [[ "$ctx" == *"…"* ]]
}

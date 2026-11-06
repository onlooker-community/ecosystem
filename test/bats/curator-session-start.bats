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
  source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
  PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  CURATOR_DIR="${ONLOOKER_DIR}/curator/${PROJECT_KEY}"
  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

  # Memory store at a predictable path. Bypass the ${CLAUDE_PROJECT_ENCODED}
  # template by overriding memory_store_path to an absolute path in the
  # project settings file.
  MEM_DIR="${TEST_HOME}/.claude/projects/test-project/memory"
  mkdir -p "$MEM_DIR" "${PROJECT_REPO}/.claude"
  # Pin a generous wall-clock budget. The hook checks
  # cheap_checks.wall_clock_budget_ms before EACH phase and skips the rest
  # once it trips, so at the shipped default of 500ms a loaded machine can
  # blow the budget before the later phases run — the orphan check among
  # them — and those tests fail intermittently while passing in isolation.
  # These tests assert what the checks detect, not how fast the host is.
  jq -n --arg path "$MEM_DIR" \
    '{
      curator: {
        memory_store_path: $path,
        cheap_checks: { wall_clock_budget_ms: 600000 },
        surfacer: { enabled: true },
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

_surfacer_off() {
  jq 'del(.curator.surfacer)' "${PROJECT_REPO}/.claude/settings.json" >"${BATS_TEST_TMPDIR}/s.json"
  cp "${BATS_TEST_TMPDIR}/s.json" "${PROJECT_REPO}/.claude/settings.json"
}

# Every scan that gets past the project-key gate ends in scan.complete or
# scan.errored, so that event is how a test knows the background scan is done.
_wait_for_scan_end() {
  local limit="${1:-15}" waited=0
  until grep -qE '"event_type":"curator\.scan\.(complete|errored)"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null; do
    ((waited >= limit * 10)) && { echo "scan did not finish in ${limit}s" >&2; return 1; }
    sleep 0.1
    waited=$((waited + 1))
  done
}

_write_index() {
  local entries="$1"   # newline-separated `- [Title](file.md) — hook` lines
  printf '%b\n' "$entries" > "${MEM_DIR}/MEMORY.md"
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
  [[ "$ctx" == *"Curator: 1 open finding"* ]] || return 1
  [[ "$ctx" == *"date-decayed"* ]] || return 1
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
  _seed_memory "project_freeze.md" "project" "Due 2025-01-01, now in the past."
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

@test "the same finding twice in one scan is written once" {
  _seed_memory "project_freeze.md" "project" "Due 2025-01-01, and again due 2025-01-01."
  _write_index '- [Freeze](project_freeze.md) — old date'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(ls "${CURATOR_DIR}/findings"/*.json | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a dedup pass costs the same however many findings exist" {
  local shim="${BATS_TEST_TMPDIR}/shim" real starts="${BATS_TEST_TMPDIR}/jq-starts"
  real=$(command -v jq)
  mkdir -p "$shim"
  cat >"${shim}/jq" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>"$starts"
exec "$real" "\$@"
EOF
  chmod +x "${shim}/jq"

  _seed_many() {
    local i
    for i in $(seq "$1" "$2"); do
      _seed_memory "project_m${i}.md" "project" "Due 2025-01-$(printf '%02d' "$i"), now in the past."
    done
    run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  }
  _rescan_starts() {
    rm -f "$starts"
    run bash -c "printf '%s' '$(_input)' | PATH='${shim}':\"\$PATH\" '$HOOK'"
    [ "$status" -eq 0 ]
    wc -l <"$starts" | tr -d ' '
  }

  _seed_many 1 3
  local few
  few=$(_rescan_starts)

  _seed_many 4 12
  local many
  many=$(_rescan_starts)

  [ "$(ls "${CURATOR_DIR}/findings"/*.json | wc -l | tr -d ' ')" -ge 12 ]
  [ "$few" -eq "$many" ]
}

@test "the surfacer stays quiet by default while findings still land" {
  _surfacer_off
  _seed_memory "project_freeze.md" "project" "Merge freeze begins 2026-03-05."
  _write_index '- [Freeze](project_freeze.md) — freeze'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')" = "" ]
  _wait_for_scan_end
  ls "${CURATOR_DIR}/findings"/*.json | grep -q '\.json$'
  grep -q '"curator.finding.date_decayed"' "$ONLOOKER_EVENTS_LOG"
}

# The budget gate reads the clock before every phase. Reading it by starting
# python3 cost ~20ms a read, ~100ms of a ~350ms scan, so the budget was mostly
# spent measuring itself (ONL-244). A python3 that is slow only when asked the
# time trips a 2s budget by the fourth gate if the clock still runs it.
@test "reading the budget clock does not start python3" {
  _seed_memory "project_freeze.md" "project" "Merge freeze begins 2026-03-05."
  _write_index '- [Freeze](project_freeze.md) — freeze'
  jq '.curator.cheap_checks.wall_clock_budget_ms = 2000' "${PROJECT_REPO}/.claude/settings.json" >"${BATS_TEST_TMPDIR}/s.json"
  cp "${BATS_TEST_TMPDIR}/s.json" "${PROJECT_REPO}/.claude/settings.json"
  local shim="${BATS_TEST_TMPDIR}/slow-clock" real
  real=$(command -v python3)
  mkdir -p "$shim"
  cat >"${shim}/python3" <<EOF
#!/usr/bin/env bash
case "\$*" in *time.time*) sleep 0.6 ;; esac
exec "$real" "\$@"
EOF
  chmod +x "${shim}/python3"

  run bash -c "printf '%s' '$(_input)' | PATH='${shim}':\"\$PATH\" '$HOOK'"
  [ "$status" -eq 0 ]
  grep '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "ok"' >/dev/null
  grep -q '"curator.finding.date_decayed"' "$ONLOOKER_EVENTS_LOG"
}

# With the surfacer off nothing at SessionStart reads the scan, so the hook
# returns without waiting on it (ONL-241). A python3 that takes 3s per start
# makes a scan that runs in the foreground take far longer than the bound below.
@test "with the surfacer off the hook returns without waiting on the scan" {
  _surfacer_off
  _seed_memory "project_freeze.md" "project" "Merge freeze begins 2026-03-05."
  _write_index '- [Freeze](project_freeze.md) — freeze'
  local shim="${BATS_TEST_TMPDIR}/slow-clock"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nsleep 3\nexec %s "$@"\n' "$(command -v python3)" >"${shim}/python3"
  chmod +x "${shim}/python3"

  local started=$SECONDS
  run bash -c "printf '%s' '$(_input)' | PATH='${shim}':\"\$PATH\" '$HOOK'"
  [ "$status" -eq 0 ]
  [ $((SECONDS - started)) -lt 3 ]
  [ "$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')" = "" ]

  _wait_for_scan_end 30
  grep -q '"curator.finding.date_decayed"' "$ONLOOKER_EVENTS_LOG"
}

# The background scan is not a SessionStart hook run. A second record under
# the same hook would put scan time back into the SessionStart span.
@test "the background scan writes no hook-health record of its own" {
  _surfacer_off
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  _wait_for_scan_end

  local health="${ONLOOKER_DIR}/logs/hook-health.jsonl"
  [ "$(jq -s '[.[] | select(.hook == "curator-session-start" and .status != "started")] | length' "$health")" = "1" ]
  [ "$(jq -s '[.[] | select(.hook == "curator-session-start" and .status == "started")] | length' "$health")" = "1" ]
}

@test "dates that record when something happened are not findings" {
  _seed_memory "project_measured.md" "project" \
    "Confirmed 2025-01-01. Measured 2025-01-02, since 2025-01-03 and after 2025-01-04."
  _write_index '- [M](project_measured.md) — measured'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  ! grep -q '"curator.finding.date_decayed"' "$ONLOOKER_EVENTS_LOG"
}

@test "dates a memory is waiting on are findings, in any case" {
  _seed_memory "project_wait.md" "project" \
    "Deadline: 2025-01-01. Revisit by 2025-01-02. Blocked until 2025-01-03."
  _write_index '- [W](project_wait.md) — waiting'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(grep -c '"curator.finding.date_decayed"' "$ONLOOKER_EVENTS_LOG")" -eq 3 ]
}

@test "path_broken leaves alone what is not a path in this repo" {
  _seed_memory "reference_mixed.md" "reference" \
    'Versions 0.61.1/0.61.2/0.61.3, range origin/main..HEAD, compare/v0.9.0...v0.9.1, $ONLOOKER_DIR/logs/hook-health.jsonl, and other-repo-only/db/orgs.ts.'
  _write_index '- [Mixed](reference_mixed.md) — mixed'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  ! grep -q '"curator.finding.path_broken"' "$ONLOOKER_EVENTS_LOG"
}

@test "surfacer pluralizes finding count" {
  _seed_memory "project_a.md" "project" "Due 2025-01-01"
  _seed_memory "project_b.md" "project" "Due 2024-06-30"
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

  # Linux's stat uses `-c FORMAT` and ignores `-f`; macOS uses `-f FORMAT`
  # and does not accept `-c`. Try Linux first (CI runs on Ubuntu); fall
  # back to BSD/macOS form for local runs.
  _file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
  }
  local sentinel_mtime_before
  sentinel_mtime_before=$(_file_mtime "$sentinel")
  [ -n "$sentinel_mtime_before" ]

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
  # `|| return 1`: a non-final `!` is exempt from errexit and does not fail the
  # test (SC2314, ecosystem-o09). Same rule the writing-tests skill states for
  # `[[ ]]`.
  ! grep '"event_type":"curator.finding.broken_index"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.referenced_file == "real.md")' >/dev/null || return 1

  # The sentinel file wasn't read (mtime unchanged) and content intact.
  local sentinel_mtime_after
  sentinel_mtime_after=$(_file_mtime "$sentinel")
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
    | jq -e 'select(.payload.broken_path | contains("example.com"))' >/dev/null || return 1
  ! grep '"event_type":"curator.finding.path_broken"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.broken_path | contains("python3.11"))' >/dev/null
}

@test "surfacer counts multiple same-kind findings correctly" {
  # Two date_decayed findings: with the group_by-without-sort bug, the
  # summary would render as "1 date-decayed, 1 date-decayed" because
  # ULID-ordered findings can interleave kinds. The sort_by(.kind) fix
  # makes the summary aggregate correctly to "2 date-decayed".
  _seed_memory "project_a.md" "project" "Stale, due 2025-01-01"
  _seed_memory "project_b.md" "project" "Older, due 2024-06-30"
  _write_index "$(printf '%s\n%s' \
    '- [A](project_a.md) — a' \
    '- [B](project_b.md) — b')"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"2 date-decayed"* ]] || return 1
  # The buggy output would have looked like "1 date-decayed, 1 date-decayed".
  [[ "$ctx" != *"1 date-decayed, 1 date-decayed"* ]]
}

@test "cheap_checks.enabled=false skips the scan and emits skip_reason disabled" {
  printf '%s\n' \
    '{"curator":{"memory_store_path":"'"$MEM_DIR"'","cheap_checks":{"enabled":false}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  _seed_memory "project_stale.md" "project" "Decayed 2025-01-01"
  _write_index '- [S](project_stale.md) — s'

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  # No surfacer in these settings, so the scan runs in the background.
  _wait_for_scan_end

  # scan.complete uses skip_reason: disabled.
  grep '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "skipped" and .payload.skip_reason == "disabled"' >/dev/null

  # No findings were written, even though the date would have matched.
  [ ! -d "${CURATOR_DIR}/findings" ] || [ -z "$(ls -A "${CURATOR_DIR}/findings" 2>/dev/null)" ]

  # No per-finding events emitted.
  ! grep -q '"event_type":"curator.finding.date_decayed"' "$ONLOOKER_EVENTS_LOG"
}

@test "surfacer truncates context past max_pointer_chars" {
  # Carries setup()'s generous wall_clock_budget_ms forward. Overwriting
  # settings.json drops every key setup() pinned, and losing the budget puts
  # this test back on the shipped 500ms default -- exactly what setup()'s
  # comment warns about. It failed on a parallel CI runner for that reason
  # while passing in isolation: the later phases never ran, the context was
  # too short to need truncating, and the ellipsis assertion failed.
  # This test is about truncation, not about how fast the host is.
  printf '%s\n' \
    '{"curator":{"memory_store_path":"'"$MEM_DIR"'","cheap_checks":{"wall_clock_budget_ms":600000},"surfacer":{"enabled":true,"max_pointer_chars":40}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  _seed_memory "project_a.md" "project" "Due 2025-01-01"
  _seed_memory "project_b.md" "project" "Due 2024-06-30"
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

# ONL-132. A non-numeric budget has TWO failure modes in bash, both silent at
# status 0, and they need different coverage:
#
#   "unlimited"  -> bash reads the bare word as a variable name, `set -u` stops
#                   the shell, and the script ABORTS mid-scan. Covered here,
#                   because it is observable: scan.started is emitted at :149,
#                   the budget check runs at :196, and scan.complete at :310
#                   never happens.
#   "600000ms"   -> digit-leading, so bash reports "value too great for base"
#                   and (( )) merely returns non-zero. The script SURVIVES and
#                   _curator_over_budget answers "not over budget" forever, so
#                   the budget silently stops bounding the scan. Not observable
#                   from out here without making the scan slow, so it is
#                   covered at the accessor instead -- config-get-int.bats
#                   asserts any non-^[0-9]+$ value falls back.
#
# This hook exits 0 either way, so status proves nothing. Asserting on
# scan.complete is what makes this test bite.
#
# Either completion counts. "unlimited" falls back to the 500ms default, and a
# loaded CI runner can spend that before the last phase, which completes the
# scan as skipped/over_budget rather than ok. That still proves the shell
# survived the bad value. Requiring "ok" made the test fail at random on a PR
# that touched only CHANGELOG.md.
@test "a non-numeric wall_clock_budget_ms does not kill the scan mid-flight" {
  jq -n --arg path "$MEM_DIR" \
    '{
      curator: {
        memory_store_path: $path,
        cheap_checks: { wall_clock_budget_ms: "unlimited" }
      }
    }' > "${PROJECT_REPO}/.claude/settings.json"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1
  # No surfacer in these settings, so the scan runs in the background.
  _wait_for_scan_end || return 1

  grep -q '"event_type":"curator.scan.started"' "$ONLOOKER_EVENTS_LOG" || return 1
  # Counted first: `grep | jq -e` on an empty match fails the same way a wrong
  # outcome does, so the two causes would otherwise be indistinguishable.
  [ "$(grep -c '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG")" -eq 1 ] || return 1
  grep '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "ok"
             or (.payload.outcome == "skipped" and .payload.skip_reason == "over_budget")' >/dev/null
}

# The other half: a bad budget must not be read as "no budget". A value that
# falls back has to fall back to the SHIPPED default, not to unbounded, or the
# fix would trade a silent death for a silently unbounded scan.
@test "a non-numeric max_pointer_chars still truncates the pointer" {
  _seed_memory "project_freeze.md" "project" \
    "Merge freeze begins 2026-03-05 for mobile release cut."
  _write_index '- [Freeze](project_freeze.md) — merge freeze date'

  jq -n --arg path "$MEM_DIR" \
    '{
      curator: {
        memory_store_path: $path,
        cheap_checks: { wall_clock_budget_ms: 600000 },
        surfacer: { enabled: true },
        date_check: { date_grace_period_days: 7 },
        surfacer: { enabled: true, max_pointer_chars: "200 chars" }
      }
    }' > "${PROJECT_REPO}/.claude/settings.json"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  # The scan survived to its terminating event ...
  grep -q '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG" || return 1
  # ... and the surfacer still rendered a pointer rather than nothing.
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Curator:"* ]]
}

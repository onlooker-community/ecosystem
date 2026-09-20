#!/usr/bin/env bats
#
# A scan that could not consult its durability markers has not judged its
# window, so it must not advance the watermark as though it had.
#
# ecosystem-449.55: during the marker outage in ecosystem-449.48 the allowlist
# was empty, every artifact clearing the length gate was dropped, and the
# watermark advanced on each of those scans anyway. 3,837 artifacts ended up
# permanently behind it. Fixing the filter does not reach back for them;
# librarian_archivist_load_since will never offer them again.
#
# The hold is keyed on filter_markers_unavailable and never on
# filter_marker_missing. The latter is an ordinary verdict, and holding on it
# would stall the pipeline permanently on any repo whose artifacts are thin --
# which is the fourth test below, the one that keeps this fix from becoming the
# bug it fixes.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  # Stand up a fake project repo so project-key resolution succeeds.
  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/librarian-watermark-test.git

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
  PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  ARCHIVIST_DIR="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
  LIBRARIAN_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}"
  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

  mkdir -p "${PROJECT_REPO}/.claude"

  # Stub `claude` CLI on PATH so no test here can reach a real model.
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"type":null,"title":"","body":"","confidence":0.2}'
STUB
  chmod +x "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${PATH}"

  # ecosystem-449.72 made the hook spawn a detached classify worker. These
  # tests assert on what the HOOK does to the watermark, so the worker is
  # stubbed out: letting a real one detach would leave a background process
  # racing the assertions below.
  NOOP_WORKER="${BATS_TEST_TMPDIR}/noop-worker.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP_WORKER"
  chmod +x "$NOOP_WORKER"

  HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-end.sh"

  # On its first scan the hook has no watermark and falls back to a relative
  # "now - bootstrap_lookback_days" window. Fixtures must be dated inside it.
  FIXTURE_CREATED_AT=$(relative_iso_days_ago 1)
}

# Helper: write an archivist artifact for the project.
_seed_artifact() {
  local kind="$1" id="$2" summary="$3" detail="$4" created_at="${5:-$FIXTURE_CREATED_AT}"
  local dir="${ARCHIVIST_DIR}/${kind}"
  mkdir -p "$dir"
  jq -n \
    --arg id "$id" --arg kind "${kind%s}" \
    --arg project_key "$PROJECT_KEY" \
    --arg summary "$summary" --arg detail "$detail" \
    --arg created_at "$created_at" --arg session_id "sess-1" \
    '{ id: $id, kind: $kind, project_key: $project_key, source: "local",
       created_at: $created_at, updated_at: $created_at,
       summary: $summary, detail: $detail, files: [], session_id: $session_id }' \
    > "${dir}/${id}.json"
}

_hook_input() {
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-watermark-test" \
    '{cwd: $cwd, session_id: $sid, hook_event_name: "SessionEnd"}'
}

_settings() {
  cat > "${PROJECT_REPO}/.claude/settings.json"
}

# Run the hook with the detached worker stubbed out.
_run_hook() {
  run env LIBRARIAN_CLASSIFY_WORKER="$NOOP_WORKER" \
    bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
}

@test "a scan whose markers were unavailable does not advance the watermark" {
  # Markers empty => every artifact past the length gate is dropped as a
  # configuration fault, not judged. Advancing here is what put 3,837
  # artifacts permanently behind the watermark (ecosystem-449.55).
  echo '{"librarian":{"durability_filter":{"marker_phrases":[]}}}' | _settings
  _seed_artifact "decisions" "01FAULTHOLD00000000000001" \
    "We chose the queue" \
    "We chose the queue because the old path dropped events on every restart."

  local before
  before=$(cat "${LIBRARIAN_DIR}/last_scan.json" 2>/dev/null || echo "absent")

  _run_hook
  [ "$status" -eq 0 ]

  local after
  after=$(cat "${LIBRARIAN_DIR}/last_scan.json" 2>/dev/null || echo "absent")
  [ "$after" = "$before" ]
}

@test "an ordinary missed marker still advances the watermark" {
  # The case that keeps this fix from becoming the bug it fixes. A hold on
  # ordinary verdicts would stall the pipeline permanently on any repo whose
  # artifacts are thin. Markers are left at their shipped defaults here, so
  # this artifact is dropped filter_marker_missing - a real verdict.
  _seed_artifact "decisions" "01ORDINARYMISS0000000001" \
    "Ran the suite" \
    "Ran the suite again this morning and everything went green on the first try."

  _run_hook
  [ "$status" -eq 0 ]
  [ -f "${LIBRARIAN_DIR}/last_scan.json" ]
  jq -e '.scanned_at' "${LIBRARIAN_DIR}/last_scan.json" >/dev/null
}

@test "a short artifact alone never triggers a hold" {
  _seed_artifact "decisions" "01SHORTDETAIL00000000001" "Fixed it" "too short"

  _run_hook
  [ "$status" -eq 0 ]
  jq -e '.scanned_at' "${LIBRARIAN_DIR}/last_scan.json" >/dev/null
}

@test "past the ceiling the scan advances and reports the abandonment" {
  # A ceiling of 1 with a single seeded artifact satisfies
  # ARTIFACT_COUNT >= MAX_FAULT_RETRY, which is why this trips the cap without
  # seeding hundreds of files.
  echo '{"librarian":{"durability_filter":{"marker_phrases":[]},
         "scan":{"max_fault_retry_artifacts":1}}}' | _settings
  _seed_artifact "decisions" "01RETRYCAP00000000000001" \
    "We chose the queue" \
    "We chose the queue because the old path dropped events on every restart."

  _run_hook
  [ "$status" -eq 0 ]

  jq -e '.scanned_at' "${LIBRARIAN_DIR}/last_scan.json" >/dev/null
  grep '"event_type":"librarian.candidate.dropped"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.reason == "retry_cap_exceeded")' >/dev/null
}

@test "the abandonment reason replaces the fault reason rather than joining it" {
  echo '{"librarian":{"durability_filter":{"marker_phrases":[]},
         "scan":{"max_fault_retry_artifacts":1}}}' | _settings
  _seed_artifact "decisions" "01RETRYCAP00000000000002" \
    "We chose the queue" \
    "We chose the queue because the old path dropped events on every restart."

  _run_hook
  [ "$status" -eq 0 ]

  local n
  n=$(grep -c '"reason":"filter_markers_unavailable"' "$ONLOOKER_EVENTS_LOG" || true)
  [ "$n" -eq 0 ]
}

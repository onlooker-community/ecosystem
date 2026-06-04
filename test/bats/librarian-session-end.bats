#!/usr/bin/env bats
#
# Exercises the librarian SessionEnd scan pipeline end-to-end with a stub
# `claude` CLI. Verifies:
#   - Disabled config: no proposals, no events.
#   - Empty archivist dir: scan.started + scan.complete{outcome: empty}
#     emitted, watermark advances.
#   - Synthetic artifacts that pass durability filter and classifier:
#     proposals land on disk with the expected provenance and scan events
#     report the correct counts.
#   - Durability-filtered artifacts (no marker phrase) emit
#     candidate.dropped events.

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
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/librarian-scan-test.git

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
  PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  ARCHIVIST_DIR="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
  LIBRARIAN_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}"
  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

  # Project-scoped settings.json that enables librarian.
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"librarian":{"enabled":true}}' > "${PROJECT_REPO}/.claude/settings.json"

  # Stub `claude` CLI on PATH. Returns a deterministic classifier response
  # based on the artifact's summary contents.
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
# Read the prompt from stdin and decide which classifier response to emit.
prompt=$(cat)
if [[ "$prompt" == *"prefer-functional-stub"* ]]; then
  printf '%s' '{"type":"feedback","title":"Prefer functional patterns","body":"User prefers functional patterns over class-based.\n\n**Why:** Stated explicitly during code review.\n**How to apply:** Default to plain functions and composition.","confidence":0.84}'
elif [[ "$prompt" == *"compliance-stub"* ]]; then
  printf '%s' '{"type":"project","title":"Auth rewrite is compliance driven","body":"Auth middleware rewrite is driven by legal/compliance requirements around session token storage.\n\n**Why:** Compliance ask, not tech debt cleanup.\n**How to apply:** Favor compliance posture over ergonomics when scoping.","confidence":0.91}'
elif [[ "$prompt" == *"low-conf-stub"* ]]; then
  printf '%s' '{"type":"user","title":"User edits","body":"User edits files.","confidence":0.4}'
else
  printf '%s' '{"type":null,"title":"","body":"","confidence":0.2}'
fi
STUB
  chmod +x "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${PATH}"

  HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-end.sh"
}

# Helper: write an archivist artifact for the project.
_seed_artifact() {
  local kind="$1" id="$2" summary="$3" detail="$4" created_at="${5:-2026-06-01T12:00:00Z}"
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
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "sess-end-test" \
    '{cwd: $cwd, session_id: $sid, hook_event_name: "SessionEnd"}'
}

@test "session-end is a no-op when librarian is disabled" {
  rm -f "${PROJECT_REPO}/.claude/settings.json"
  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  # No proposals written.
  [ ! -d "${LIBRARIAN_DIR}/proposals" ] || [ -z "$(ls -A "${LIBRARIAN_DIR}/proposals" 2>/dev/null)" ]
  # No events emitted.
  [ ! -f "$ONLOOKER_EVENTS_LOG" ] || ! grep -q 'librarian' "$ONLOOKER_EVENTS_LOG"
}

@test "session-end emits empty scan when archivist has nothing" {
  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  # scan.started fired with artifact_count_in_window = 0.
  grep -q '"event_type":"librarian.scan.started"' "$ONLOOKER_EVENTS_LOG"
  grep '"event_type":"librarian.scan.started"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.artifact_count_in_window == 0' >/dev/null

  # scan.complete fired with outcome=empty and zero counts.
  grep -q '"event_type":"librarian.scan.complete"' "$ONLOOKER_EVENTS_LOG"
  grep '"event_type":"librarian.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "empty" and .payload.candidates_proposed == 0 and .payload.candidates_dropped == 0' >/dev/null

  # Watermark advanced for next scan.
  [ -f "${LIBRARIAN_DIR}/last_scan.json" ]
  jq -e '.scanned_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "${LIBRARIAN_DIR}/last_scan.json" >/dev/null
}

@test "session-end proposes promotion for marker-phrase + classifier success" {
  # Seed two promotable artifacts and one filter-rejected one.
  _seed_artifact "decisions" "01PROPOSEEFEEDBACK00000000" \
    "User prefers functional patterns prefer-functional-stub" \
    "User explicitly said: always prefer plain functions over classes when adding new code in the api layer."

  _seed_artifact "decisions" "01PROPOSEEPROJECT000000000" \
    "Compliance-driven auth rewrite compliance-stub" \
    "The reason for the auth middleware rewrite is legal compliance, not tech debt; remember this when sizing scope."

  _seed_artifact "open_questions" "01FILTERREJECTED000000000" \
    "ad hoc question" \
    "this short text contains no marker phrase and should be filtered out before the classifier runs"

  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  # Two proposals on disk.
  proposals=("${LIBRARIAN_DIR}/proposals"/*.json)
  [ "${#proposals[@]}" -eq 2 ]

  # Both carry provenance back to their source artifact.
  for p in "${proposals[@]}"; do
    jq -e '.status == "pending" and .conflict_state == "none"' "$p" >/dev/null
    jq -e '.proposed.type | IN("user", "feedback", "project", "reference")' "$p" >/dev/null
    jq -e '.proposed.classifier_confidence >= 0.6' "$p" >/dev/null
    jq -e '(.source_artifact_ids | length) > 0' "$p" >/dev/null
  done

  # scan.started reported the right window size (2 marker matches + 1 filtered = 3).
  grep '"event_type":"librarian.scan.started"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.artifact_count_in_window == 3' >/dev/null

  # candidate.proposed fired twice with correct types.
  proposed_types=$(grep '"event_type":"librarian.candidate.proposed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -r '.payload.memory_type' | sort | paste -sd, -)
  [ "$proposed_types" = "feedback,project" ]

  # candidate.dropped fired for the marker-missing artifact.
  grep '"event_type":"librarian.candidate.dropped"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.reason == "filter_marker_missing")' >/dev/null

  # scan.complete with ok outcome and accurate counts.
  scan_complete=$(grep '"event_type":"librarian.scan.complete"' "$ONLOOKER_EVENTS_LOG")
  echo "$scan_complete" | jq -e '.payload.outcome == "ok" and .payload.candidates_proposed == 2 and .payload.candidates_dropped >= 1' >/dev/null
}

@test "session-end drops candidates below confidence floor" {
  _seed_artifact "decisions" "01LOWCONFCANDIDATE0000000" \
    "low-conf-stub trigger" \
    "always prefer some thing because reasons that show a marker phrase but the stub returns low confidence"

  run bash -c "printf '%s' '$(_hook_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  # No proposal written.
  [ ! -d "${LIBRARIAN_DIR}/proposals" ] || [ -z "$(ls -A "${LIBRARIAN_DIR}/proposals" 2>/dev/null)" ]

  # candidate.dropped fired with low_confidence reason.
  grep '"event_type":"librarian.candidate.dropped"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.reason == "low_confidence")' >/dev/null

  # scan.complete reports empty outcome (zero proposals).
  grep '"event_type":"librarian.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "empty" and .payload.candidates_proposed == 0 and .payload.candidates_dropped >= 1' >/dev/null
}

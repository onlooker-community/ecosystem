#!/usr/bin/env bats
#
# Replaying artifacts that were declined no_versions. A decline is terminal —
# librarian_lesson_seen reads declined.jsonl — so recovering one means rewriting
# that record, which is the only place in the pipeline that removes a terminal
# decision. Only no_versions is eligible: no_resolution and schema_invalid are
# still correct refusals (ONL-107).

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
}

_reconsider_setup() {
  for lib in librarian-project-key librarian-ulid librarian-storage \
    librarian-lesson-storage librarian-lesson-validate librarian-config \
    librarian-archivist-reader librarian-lesson-transform librarian-emit \
    librarian-cli; do
    # shellcheck disable=SC1091
    source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh"
  done

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-reconsider.git
  PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]
  LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_config_load "$PROJECT_REPO"

  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
if [[ "$prompt" == *"<scope-mode>unscoped</scope-mode>"* ]]; then
  printf '%s' '{"claim":"A bare Release-As footer bumps every component","rationale":"release-please applies an unscoped footer to the whole manifest.","evidence":{"resolution":"Scope the bump in the manifest instead."},"applies_to":{"stack":["release-please"],"scope":{"kind":"unscoped"},"file_patterns":[],"task_kinds":[]}}'
else
  printf '%s' 'not json at all'
fi
STUB
  chmod +x "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${PATH}"
}

# Writes an archivist artifact where librarian-archivist-reader.sh reads them.
_seed_artifact_on_disk() {
  local dir="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions"
  mkdir -p "$dir"
  jq -cn --arg id "$1" --arg s "$2" --arg d "$3" --arg k "$PROJECT_KEY" \
    '{id: $id, kind: "decision", project_key: $k, session_id: "sess-1",
      created_at: "2026-08-03T15:59:48Z", summary: $s, detail: $d, files: []}' \
    > "${dir}/$1.json"
}

@test "remove_declined removes only the named reason and reports the ids" {
  _reconsider_setup
  printf '%s\n' \
    '{"artifact_id":"01M3B87J7046SJE5BECNMP670K","reason":"no_versions","declined_at":"2026-09-20T17:39:59Z"}' \
    '{"artifact_id":"01M3B93JPGAKHGEQ5KD9N836HD","reason":"no_resolution","declined_at":"2026-09-21T23:18:55Z"}' \
    '{"artifact_id":"01M33440PGTWP4QMMG1BVA52DR","reason":"no_versions","declined_at":"2026-09-21T23:18:55Z"}' \
    > "${LESSONS_DIR}/declined.jsonl"

  run librarian_lesson_remove_declined "$PROJECT_KEY" no_versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"01M3B87J7046SJE5BECNMP670K"* ]]
  [[ "$output" == *"01M33440PGTWP4QMMG1BVA52DR"* ]]
  [ "$(wc -l < "${LESSONS_DIR}/declined.jsonl" | tr -d ' ')" -eq 1 ]
  jq -e '.reason == "no_resolution"' < "${LESSONS_DIR}/declined.jsonl"
}

@test "remove_declined survives a truncated trailing line" {
  _reconsider_setup
  printf '%s\n' \
    '{"artifact_id":"01M3B87J7046SJE5BECNMP670K","reason":"no_versions"}' \
    '{"artifact_id":"01M33440PGTWP' \
    > "${LESSONS_DIR}/declined.jsonl"
  run librarian_lesson_remove_declined "$PROJECT_KEY" no_versions
  [ "$status" -eq 0 ]
  [[ "$output" == *"01M3B87J7046SJE5BECNMP670K"* ]]
  # The unparseable line is not a matching decline, so it must survive rather
  # than be swept up by the rewrite.
  grep -q "01M33440PGTWP" "${LESSONS_DIR}/declined.jsonl"
}

@test "load_by_id returns the artifact and refuses a non-ULID id" {
  _reconsider_setup
  _seed_artifact_on_disk "01M3B87J7046SJE5BECNMP670K" "summary here" "detail here"
  run librarian_archivist_load_by_id "$PROJECT_KEY" "01M3B87J7046SJE5BECNMP670K"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.summary == "summary here"'

  run librarian_archivist_load_by_id "$PROJECT_KEY" "../../etc/passwd"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "reconsider replays a no_versions decline into a parked proposal" {
  _reconsider_setup
  # Carries a version-shaped token on purpose: every real no_versions decline
  # does, because passing the pre-gate is how it reached the model at all. A
  # token-free fixture here passes whether or not reconsider forces the route.
  _seed_artifact_on_disk "01M3B87J7046SJE5BECNMP670K" \
    "restore the ecosystem version above 0.61.10" \
    "A bare Release-As footer on 39b3bba hit every component. See 449.55."
  printf '%s\n' \
    '{"artifact_id":"01M3B87J7046SJE5BECNMP670K","reason":"no_versions","declined_at":"2026-09-20T17:39:59Z"}' \
    > "${LESSONS_DIR}/declined.jsonl"

  run librarian_cli lessons reconsider "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [ "$(ls "${LESSONS_DIR}/proposals" | wc -l | tr -d ' ')" -eq 1 ]
  jq -e '.candidate.applies_to.scope.kind == "unscoped"' \
    "${LESSONS_DIR}/proposals/"*.json
}

@test "reconsider leaves a decline in place when its artifact is gone" {
  _reconsider_setup
  printf '%s\n' \
    '{"artifact_id":"01M3B87J7046SJE5BECNMP670K","reason":"no_versions","declined_at":"2026-09-20T17:39:59Z"}' \
    > "${LESSONS_DIR}/declined.jsonl"
  run librarian_cli lessons reconsider "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  grep -q "01M3B87J7046SJE5BECNMP670K" "${LESSONS_DIR}/declined.jsonl"
  [[ "$output" == *"artifact missing"* ]]
}

@test "reconsider reports nothing to do when no no_versions declines exist" {
  _reconsider_setup
  printf '%s\n' \
    '{"artifact_id":"01M3B93JPGAKHGEQ5KD9N836HD","reason":"no_resolution"}' \
    > "${LESSONS_DIR}/declined.jsonl"
  run librarian_cli lessons reconsider "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to reconsider"* ]]
  grep -q "no_resolution" "${LESSONS_DIR}/declined.jsonl"
}

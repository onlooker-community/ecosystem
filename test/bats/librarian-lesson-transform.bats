#!/usr/bin/env bats
#
# Pure validation rules for the lesson transform. No I/O, no CLI, no project
# key — these are the rules every candidate must satisfy before it is written.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
}

_artifact() {
  jq -cn --arg s "$1" --arg d "$2" '{summary: $s, detail: $d}'
}

@test "pregate accepts an artifact carrying a dotted version" {
  run librarian_lesson_pregate "$(_artifact "Vitest 4.1.9 breaks" "against Vite 5.4.21")"
  [ "$status" -eq 0 ]
}

@test "pregate accepts a v-prefixed version" {
  run librarian_lesson_pregate "$(_artifact "broken on v5" "see notes")"
  [ "$status" -eq 0 ]
}

@test "pregate accepts an x-range" {
  run librarian_lesson_pregate "$(_artifact "fails on 5.x" "see notes")"
  [ "$status" -eq 0 ]
}

@test "pregate skips an artifact with no version token at all" {
  run librarian_lesson_pregate "$(_artifact "Prefer functional patterns" "User said so during review.")"
  [ "$status" -eq 1 ]
}

@test "valid_range accepts the four comparator forms and a two-sided range" {
  for r in "<6" "<=6" "=6" ">4" ">=4" ">=4 <6"; do
    run librarian_lesson_valid_range "$r"
    [ "$status" -eq 0 ]
  done
}

@test "valid_range rejects npm-style ranges a model reaches for by default" {
  for r in "^5.4.21" "~5" "5.x" "5.4.21" "" "latest"; do
    run librarian_lesson_valid_range "$r"
    [ "$status" -eq 1 ]
  done
}

@test "valid_range rejects unbounded lower bounds that would never expire" {
  for r in ">=0" ">=0.0" ">=0.0.0" ">0"; do
    run librarian_lesson_valid_range "$r"
    [ "$status" -eq 1 ]
  done
}

@test "valid_range rejects a string with an embedded newline containing a valid line" {
  # grep's ^/$ anchor to line boundaries, not string boundaries; a naive
  # grep-based check would let a compound string like this slip through
  # because its second line ("<6") is independently valid.
  run librarian_lesson_valid_range "$(printf '>=999\n<6')"
  [ "$status" -eq 1 ]
}

_candidate() {
  jq -cn --argjson versions "$1" --argjson stack "$2" '{
    claim: "Vitest 4 cannot import vite/module-runner on Vite 5",
    rationale: "vite/module-runner ships in Vite 6; Vitest 4 assumes it exists.",
    evidence: {
      artifact_ids: ["01KZ45MKAM734ZS7JK24D2DK0R"],
      session_ids: ["sess-1"],
      project_key: "6a7678979e31",
      observed_at: "2026-08-03T15:59:48Z",
      resolution: "Pin vitest to 3.x until Vite 6 lands."
    },
    applies_to: {
      stack: $stack,
      scope: {kind: "versioned", versions: $versions},
      file_patterns: [],
      task_kinds: []
    }
  }'
}

@test "validate_candidate accepts a well-formed versioned candidate" {
  run librarian_lesson_validate_candidate \
    "$(_candidate '{"vite":"<6","vitest":">=4"}' '["vite","vitest"]')"
  [ "$status" -eq 0 ]
}

@test "validate_candidate rejects a versions key absent from stack" {
  run librarian_lesson_validate_candidate \
    "$(_candidate '{"vite":"<6","vitest":">=4"}' '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an invalid range inside an otherwise valid candidate" {
  run librarian_lesson_validate_candidate \
    "$(_candidate '{"vite":"^5.4.21"}' '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an empty versions object" {
  run librarian_lesson_validate_candidate "$(_candidate '{}' '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects a missing resolution" {
  candidate=$(_candidate '{"vite":"<6"}' '["vite"]' | jq -c 'del(.evidence.resolution)')
  run librarian_lesson_validate_candidate "$candidate"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an empty resolution" {
  candidate=$(_candidate '{"vite":"<6"}' '["vite"]' | jq -c '.evidence.resolution = ""')
  run librarian_lesson_validate_candidate "$candidate"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects version_independent even when well-formed" {
  candidate=$(_candidate '{"vite":"<6"}' '["vite"]' \
    | jq -c '.applies_to.scope = {kind: "version_independent", justification: "git behavior is stable"}')
  run librarian_lesson_validate_candidate "$candidate"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects an empty-string range" {
  run librarian_lesson_validate_candidate \
    "$(_candidate '{"vite":""}' '["vite"]')"
  [ "$status" -eq 1 ]
}

@test "validate_candidate rejects a versions value with an embedded newline" {
  # A single value like ">=999\n<6" must not be split by a newline-delimited
  # read into two lines that each pass individually.
  local newline_range
  newline_range=$(printf '>=999\n<6')
  run librarian_lesson_validate_candidate \
    "$(_candidate "$(jq -cn --arg v "$newline_range" '{vite: $v}')" '["vite"]')"
  [ "$status" -eq 1 ]
}

# ----------------------------------------------------------------------------
# Storage: the lessons/ subtree, proposal writes, the declined ledger, and
# artifact-keyed idempotency.
# ----------------------------------------------------------------------------

_storage_setup() {
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-fixture.git
  PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]
  LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
}

@test "storage_init creates the proposals and approved directories" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  [ -d "${LESSONS_DIR}/proposals" ]
  [ -d "${LESSONS_DIR}/approved" ]
}

@test "write_proposal lands a ULID-keyed file carrying its artifact_id" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  candidate=$(jq -cn '{claim: "c", rationale: "r"}')
  id=$(librarian_lesson_write_proposal "$PROJECT_KEY" "$candidate" "01KZ45MKAM734ZS7JK24D2DK0R")
  [ -n "$id" ]
  [ -f "${LESSONS_DIR}/proposals/${id}.json" ]
  jq -e '.artifact_id == "01KZ45MKAM734ZS7JK24D2DK0R" and .candidate.claim == "c"' \
    "${LESSONS_DIR}/proposals/${id}.json"
}

@test "append_declined writes one JSONL line per decline" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZEAF9EY4C6TTR0V7YFN9VYJ" "no_versions"
  [ "$(wc -l < "${LESSONS_DIR}/declined.jsonl")" -eq 2 ]
  head -n 1 "${LESSONS_DIR}/declined.jsonl" \
    | jq -e '.artifact_id == "01KZ45MKAM734ZS7JK24D2DK0R" and .reason == "no_resolution"'
}

@test "seen reports a fresh artifact as new" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 1 ]
}

@test "seen finds an artifact recorded in declined.jsonl" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 0 ]
}

@test "seen finds an artifact already sitting in proposals" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_write_proposal "$PROJECT_KEY" "$(jq -cn '{claim: "c"}')" "01KZ45MKAM734ZS7JK24D2DK0R"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 0 ]
}

@test "seen finds an artifact already promoted into the approved pool" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  jq -n '{artifact_id: "01KZ45MKAM734ZS7JK24D2DK0R"}' \
    > "${LESSONS_DIR}/approved/01KZ45MKGQ7QZWMABQ4H12SHSV.json"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 0 ]
}

@test "seen still finds a declined artifact when declined.jsonl has a truncated trailing line" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  # Simulate a process killed mid-append: a trailing line that never closed.
  printf '{"artifact_id":"01KZEAF9EY4C6TTR0V7YFN9VYJ","reason":"trunc' \
    >> "${LESSONS_DIR}/declined.jsonl"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 0 ]
}

@test "seen still reports a genuinely absent artifact as new when declined.jsonl has a truncated trailing line" {
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  printf '{"artifact_id":"01KZEAF9EY4C6TTR0V7YFN9VYJ","reason":"trunc' \
    >> "${LESSONS_DIR}/declined.jsonl"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKGQ7QZWMABQ4H12SHSV"
  [ "$status" -eq 1 ]
}

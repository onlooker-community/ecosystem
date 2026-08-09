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

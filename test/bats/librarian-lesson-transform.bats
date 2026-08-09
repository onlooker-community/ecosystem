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

@test "seen does not poison its scan on a valid-JSON non-object ledger line" {
  # fromjson? only guards the *parse* — a line that is valid JSON but not an
  # object (a bare 123) parses cleanly, then errors on `.artifact_id`
  # indexing, which aborts the whole jq invocation unless `objects` filters
  # it out first. That failure mode reads every previously-declined artifact
  # as unseen, so both directions matter here: a real decline must still be
  # found despite the poison line, and a genuinely new artifact must not be
  # swept up as a false match by whatever mechanism tolerates that line.
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  printf '123\n' >> "${LESSONS_DIR}/declined.jsonl"

  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
  [ "$status" -eq 0 ]

  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKGQ7QZWMABQ4H12SHSV"
  [ "$status" -eq 1 ]
}

@test "seen reports a genuinely absent artifact as new, not merely 'the ledger has entries'" {
  # This is deliberately NOT just "seen returns 1 for an absent id with a
  # truncated line present" — that formulation cannot discriminate a correct
  # implementation from a broken one. Whether the truncated line makes jq
  # error out entirely or jq completes and simply finds no match, the
  # calling code treats both as "not found" and falls through to the same
  # answer either way, so a standalone not-found assertion there passes
  # regardless of which code path produced it.
  #
  # What a not-found assertion CAN catch is a false-positive implementation:
  # one that treats "the ledger is non-empty" or "contains any well-formed
  # entry" as "seen", instead of checking whether an entry actually matches
  # this artifact_id. The ledger below carries two genuine, well-formed,
  # non-matching declines plus the same truncated trailing line, so the only
  # way this test fails is a false match.
  _storage_setup
  librarian_lesson_storage_init "$PROJECT_KEY"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZEAF9EY4C6TTR0V7YFN9VYJ" "no_versions"
  printf '{"artifact_id":"01KZ45MKS84KPZQNWC02Z8FE0K","reason":"trunc' \
    >> "${LESSONS_DIR}/declined.jsonl"
  run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKGQ7QZWMABQ4H12SHSV"
  [ "$status" -eq 1 ]
}

# ----------------------------------------------------------------------------
# Transform: prompt building, the `claude -p` call, and orchestration. A
# stubbed `claude` on PATH stands in for the model.
# ----------------------------------------------------------------------------

_transform_setup() {
  _storage_setup
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
  librarian_config_load "$PROJECT_REPO"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-transform.sh"
  librarian_lesson_storage_init "$PROJECT_KEY"

  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
# Stub-selector markers are checked before the generic "module-runner"
# content match: several fixtures embed real vitest/vite prose (which
# contains "module-runner") alongside their marker, and the marker names
# the intended stub behavior.
if [[ "$prompt" == *"no-resolution-stub"* ]]; then
  printf '%s' '{"eligible":false,"reason":"no_resolution"}'
elif [[ "$prompt" == *"no-versions-stub"* ]]; then
  printf '%s' '{"eligible":false,"reason":"no_versions"}'
elif [[ "$prompt" == *"npm-range-stub"* ]]; then
  printf '%s' '{"claim":"c","rationale":"r","evidence":{"resolution":"fix"},"applies_to":{"stack":["vite"],"scope":{"kind":"versioned","versions":{"vite":"^5.4.21"}},"file_patterns":[],"task_kinds":[]}}'
elif [[ "$prompt" == *"module-runner"* ]]; then
  printf '%s' '{"claim":"Vitest 4 cannot import vite/module-runner on Vite 5","rationale":"vite/module-runner ships in Vite 6; Vitest 4 assumes it exists.","evidence":{"resolution":"Pin vitest to 3.x until Vite 6 lands."},"applies_to":{"stack":["vite","vitest"],"scope":{"kind":"versioned","versions":{"vite":"<6","vitest":">=4"}},"file_patterns":[],"task_kinds":[]}}'
else
  printf '%s' 'not json at all'
fi
STUB
  chmod +x "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${PATH}"
}

_seed() {
  jq -cn --arg id "$1" --arg s "$2" --arg d "$3" --arg k "$PROJECT_KEY" \
    '{id: $id, kind: "decision", project_key: $k, session_id: "sess-1",
      created_at: "2026-08-03T15:59:48Z", summary: $s, detail: $d}'
}

@test "transform_one proposes a candidate for a groundable artifact" {
  _transform_setup
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [[ "$output" == proposed:* ]]
  id="${output#proposed:}"
  jq -e '.candidate.applies_to.scope.versions.vite == "<6"
     and .candidate.applies_to.scope.versions.vitest == ">=4"' \
    "${LESSONS_DIR}/proposals/${id}.json"
}

@test "transform_one declines the real vitest artifact for having no resolution" {
  _transform_setup
  # The artifact that motivated the pipeline. Its session ended on an open
  # question — the fix was never found — so it cannot become a lesson.
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" \
    "no-resolution-stub: Vitest 4.1.9 / Vite 5.x mismatch confirmed as real, blocking bug." \
    "Running pnpm test reproduces failures. Vitest 4.1.9 attempts to import vite/module-runner which does not exist in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [ "$output" = "declined:no_resolution" ]
  tail -n 1 "${LESSONS_DIR}/declined.jsonl" | jq -e '.reason == "no_resolution"'
}

@test "transform_one declines when the model cannot infer versions" {
  _transform_setup
  art=$(_seed "01KZ45MKGQ7QZWMABQ4H12SHSV" "no-versions-stub: 5.4 something" "detail 1.2")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "declined:no_versions" ]
}

@test "transform_one declines unparseable model output as transform_invalid" {
  _transform_setup
  art=$(_seed "01KZ45MKME229J0QK0690TREAB" "garbage 1.0" "detail 2.0")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "declined:transform_invalid" ]
}

@test "transform_one declines an npm-style range as schema_invalid" {
  _transform_setup
  art=$(_seed "01KZ45MKS84KPZQNWC02Z8FE0K" "npm-range-stub 5.4" "detail 1.0")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "declined:schema_invalid" ]
}

@test "transform_one skips a version-free artifact without touching the ledger" {
  _transform_setup
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Prefer functional patterns" "User said so.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "skipped:pregate" ]
  [ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "a missing claude CLI is not a verdict and writes nothing" {
  _transform_setup
  rm -f "${STUB_BIN}/claude"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [ "$output" = "unavailable" ]
  [ ! -f "${LESSONS_DIR}/declined.jsonl" ]
  [ -z "$(ls -A "${LESSONS_DIR}/proposals")" ]
}

@test "an empty model response is not a verdict and writes nothing" {
  _transform_setup
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf ''
STUB
  chmod +x "${STUB_BIN}/claude"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x" "module-runner missing in 5.4.21")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "unavailable" ]
  [ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "an already-declined artifact is not sent to the model a second time" {
  _transform_setup
  librarian_lesson_append_declined "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R" "no_resolution"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x" "module-runner missing in 5.4.21")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$output" = "skipped:seen" ]
  [ "$(wc -l < "${LESSONS_DIR}/declined.jsonl")" -eq 1 ]
}

# ----------------------------------------------------------------------------
# Review round 1 fixes: config-driven timeout, tightened provenance
# validation, prose-tolerant JSON extraction, and the gaps a wrong
# implementation could slip through undetected.
# ----------------------------------------------------------------------------

@test "the reason clamp discards a reason slug the model invented" {
  # Deleting the clamp in librarian_lesson_transform_one lets an arbitrary
  # model-supplied reason string enter the permanent ledger unchecked.
  _transform_setup
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' '{"eligible":false,"reason":"model_made_this_up"}'
STUB
  chmod +x "${STUB_BIN}/claude"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x" "module-runner missing in 5.4.21")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [ "$output" = "declined:transform_invalid" ]
  tail -n 1 "${LESSONS_DIR}/declined.jsonl" | jq -e '.reason == "transform_invalid"'
}

@test "transform_one stitches all four provenance fields, not just versions" {
  # Swapping session_id/artifact_id or using the wrong timestamp source
  # passed every other assertion in this file before this test existed.
  #
  # The two bare assertions below are chained with && into one statement
  # rather than left as separate lines: under the macOS system bash (3.2)
  # that `bats` resolves via `#!/usr/bin/env bash`, a bare `[[ ]]` that
  # fails and isn't the test's last statement does not abort the test —
  # only a `&&`/`||` chain's own short-circuited exit status reliably gates
  # regardless of bash version. See ecosystem-75a.
  _transform_setup
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  id="${output#proposed:}"
  [ "$status" -eq 0 ] \
    && [[ "$output" == proposed:* ]] \
    && jq -e --arg pk "$PROJECT_KEY" '
      .candidate.evidence.artifact_ids == ["01KZ45MKAM734ZS7JK24D2DK0R"]
      and .candidate.evidence.session_ids == ["sess-1"]
      and .candidate.evidence.project_key == $pk
      and .candidate.evidence.observed_at == "2026-08-03T15:59:48Z"
    ' "${LESSONS_DIR}/proposals/${id}.json"
}

@test "build_prompt states there is no version-independent option and forbids npm ranges" {
  # All three checks are chained with && into one statement — see the note
  # on the provenance-stitching test above: a bare, non-last `[[ ]]` does
  # not gate the test under the bash 3.2 that `bats` resolves on this
  # machine. Only the third check was originally last, so deleting the
  # "no version-independent option" paragraph from build_prompt passed
  # this test as first written — the check for it ran, failed, and the
  # failure was silently swallowed.
  _transform_setup
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x" "module-runner missing in 5.4.21")
  prompt=$(librarian_lesson_build_prompt "$art")
  [[ "$prompt" == *"no version-independent option"* ]] \
    && [[ "$prompt" == *'"^5.4.21"'* ]] \
    && [[ "$prompt" == *'">=0"'* ]]
}

@test "transform_one declines a provenance-less artifact instead of writing invalid evidence" {
  # archivist-extract.sh writes session_id: null when the hook payload
  # lacked one. That must not silently become evidence.session_ids: [""] in
  # a written proposal — it must fail validation like any other schema
  # violation, not get buried as though it had been judged and approved.
  _transform_setup
  art=$(jq -cn --arg id "01KZ45MKAM734ZS7JK24D2DK0R" --arg k "$PROJECT_KEY" \
    '{id: $id, kind: "decision", project_key: $k, session_id: null,
      created_at: "2026-08-03T15:59:48Z",
      summary: "Vitest 4.1.9 / Vite 5.x mismatch",
      detail: "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21."}')
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [ "$output" = "declined:schema_invalid" ]
  [ -z "$(ls -A "${LESSONS_DIR}/proposals")" ]
}

@test "transform_one recovers a candidate wrapped in prose instead of declining it as unparseable" {
  _transform_setup
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' 'Here is the JSON you requested: {"claim":"Vitest 4 cannot import vite/module-runner on Vite 5","rationale":"vite/module-runner ships in Vite 6; Vitest 4 assumes it exists.","evidence":{"resolution":"Pin vitest to 3.x until Vite 6 lands."},"applies_to":{"stack":["vite","vitest"],"scope":{"kind":"versioned","versions":{"vite":"<6","vitest":">=4"}},"file_patterns":[],"task_kinds":[]}} Hope that helps!'
STUB
  chmod +x "${STUB_BIN}/claude"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ]
  [[ "$output" == proposed:* ]]
}

@test "librarian_lesson_call reads timeout_seconds from config instead of hardcoding it" {
  _transform_setup
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"librarian":{"lesson_transform":{"timeout_seconds":7}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
  librarian_config_load "$PROJECT_REPO"

  TIMEOUT_CAPTURE="${BATS_TEST_TMPDIR}/timeout-seconds-used"
  export TIMEOUT_CAPTURE
  cat > "${STUB_BIN}/timeout" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$1" > "${TIMEOUT_CAPTURE}"
shift
exec "$@"
STUB
  chmod +x "${STUB_BIN}/timeout"

  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.")
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  [ "$status" -eq 0 ] \
    && [ "$(cat "$TIMEOUT_CAPTURE")" = "7" ]
}

@test "a pathologically large response terminates quickly instead of hanging on extraction" {
  # _librarian_lesson_extract_json_object is a per-character bash scan —
  # effectively O(n^2) on long input. It runs after the claude call,
  # uncapped, inside a SessionEnd hook that must not stall session end, and
  # nothing bounds the model's response size (claude -p has no such flag).
  # This response has no brace anywhere, so recovery is impossible and the
  # correct outcome is declined:transform_invalid — the test asserts that
  # verdict is reached well inside a 5s budget, not just that it's eventually
  # reached at all. 40k chars is sized to fail loudly (tens of seconds, not
  # a borderline few) if the bound in librarian_lesson_call is ever removed,
  # rather than flake near the threshold.
  _transform_setup
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' 'not json, just prose. '
printf '%*s' 40000 '' | tr ' ' 'x'
STUB
  chmod +x "${STUB_BIN}/claude"
  art=$(_seed "01KZ45MKAM734ZS7JK24D2DK0R" "Vitest 4.1.9 / Vite 5.x mismatch" \
    "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21.")

  start=$(date +%s)
  run librarian_lesson_transform_one "$PROJECT_KEY" "$art"
  end=$(date +%s)
  elapsed=$((end - start))

  [ "$status" -eq 0 ] \
    && [ "$output" = "declined:transform_invalid" ] \
    && [ "$elapsed" -lt 5 ]
}

# ----------------------------------------------------------------------------
# SessionEnd wiring: the hook runs the lesson stage over the same durability
# survivors the classifier saw and lands a proposal on disk.
# ----------------------------------------------------------------------------

@test "SessionEnd runs the lesson stage and lands a candidate on disk" {
  _transform_setup

  HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-end.sh"
  ARCHIVIST_DIR="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
  mkdir -p "${ARCHIVIST_DIR}/decisions"

  created_at=$(relative_iso_days_ago 1)
  # The detail carries "because" so this fixture clears the durability
  # filter's marker-phrase gate (plugins/librarian/scripts/lib/
  # librarian-durability.sh) — a plain version-mismatch summary with no
  # marker phrase gets dropped as filter_marker_missing before it ever
  # reaches $KEPT, regardless of whether the lesson stage runs.
  jq -n --arg id "01KZ45MKAM734ZS7JK24D2DK0R" --arg at "$created_at" --arg k "$PROJECT_KEY" \
    '{id: $id, kind: "decision", project_key: $k, session_id: "sess-1",
      created_at: $at, updated_at: $at,
      summary: "Vitest 4.1.9 / Vite 5.x mismatch, decided to pin",
      detail: "Vitest 4.1.9 imports vite/module-runner which is absent in Vite 5.4.21, because Vite 6 has not shipped yet.",
      files: ["packages/db"]}' \
    > "${ARCHIVIST_DIR}/decisions/01KZ45MKAM734ZS7JK24D2DK0R.json"

  input=$(jq -cn --arg cwd "$PROJECT_REPO" \
    '{cwd: $cwd, session_id: "sess-1", hook_event_name: "SessionEnd"}')
  run bash -c "printf '%s' '$input' | '$HOOK'"

  [ "$status" -eq 0 ]
  [ -n "$(ls -A "${LESSONS_DIR}/proposals" 2>/dev/null)" ]
}

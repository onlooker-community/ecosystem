#!/usr/bin/env bats
#
# Exercises the librarian-cli surface that the /librarian review skill
# drives. Each test seeds one or more proposals directly into the
# librarian storage layer (skipping the SessionEnd scan pipeline) and
# verifies that list/show/accept/reject/defer/status behave as the
# skill expects:
#
#   - list  → returns a count + table, sized to pending proposals only
#   - show  → renders provenance + body, fails clean on unknown id
#   - accept → writes the typed memory file with provenance frontmatter,
#              appends to MEMORY.md, sets status=accepted, emits
#              librarian.proposal.accepted
#   - reject → writes a body-hash tombstone, sets status=rejected,
#              emits librarian.proposal.rejected AND
#              librarian.tombstone.created
#   - defer → leaves status pending but stamps the proposal so a
#             reviewer can tell it was visited
#   - status → reports pending/accepted/rejected counts
#
# The CLI is sourced into the bats shell directly (it's a library, not
# a hook), so assertions can read both stdout and side-effects on disk.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/librarian-cli-test.git

  # Source the five libs the skill loads, in the same order the SKILL.md
  # walkthrough sources them. librarian-cli depends on storage + emit +
  # project-key (and indirectly config).
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-cli.sh"

  PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  LIBRARIAN_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}"
  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
  export ONLOOKER_EVENTS_LOG

  # Where librarian_cli_accept writes typed memory. The CLI derives the
  # encoded path from cwd when CLAUDE_PROJECT_ENCODED is unset; mirror
  # that derivation so tests can assert against the resulting file.
  ABS_CWD=$(cd "$PROJECT_REPO" && pwd -P)
  ENCODED=$(printf '%s' "$ABS_CWD" | sed -E 's#/#-#g')
  MEM_DIR="${TEST_HOME}/.claude/projects/${ENCODED}/memory"

  librarian_storage_init "$PROJECT_KEY"
}

# Seed a single proposal JSON file directly into the storage layer.
# Usage: _seed_proposal <id> <type> <title> <filename> <body> [confidence] [status]
_seed_proposal() {
  local id="$1" type="$2" title="$3" filename="$4" body="$5"
  local confidence="${6:-0.82}" status="${7:-pending}"
  local now json
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  json=$(jq -cn \
    --arg id "$id" \
    --arg type "$type" \
    --arg title "$title" \
    --arg filename "$filename" \
    --arg body "$body" \
    --argjson conf "$confidence" \
    --arg status "$status" \
    --arg now "$now" \
    --arg project_key "$PROJECT_KEY" \
    '{
       id: $id,
       project_key: $project_key,
       status: $status,
       conflict_state: "none",
       created_at: $now,
       updated_at: $now,
       source_session_ids: ["sess-seeded"],
       source_artifact_ids: ["01ARTIFACT00000000000000"],
       proposed: {
         type: $type,
         title: $title,
         filename: $filename,
         body: $body,
         classifier_confidence: $conf
       }
     }')
  librarian_storage_write_proposal "$PROJECT_KEY" "$id" "$json" >/dev/null
}

@test "list reports no-pending when the queue is empty" {
  run librarian_cli_list "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No pending proposals."* ]]
}

@test "list summarizes pending proposals and ignores resolved ones" {
  _seed_proposal "01LISTPENDINGA000000000000" \
    "feedback" "Prefer functional patterns" "feedback_functional.md" \
    "Body A."
  _seed_proposal "01LISTPENDINGB000000000000" \
    "project" "Auth rewrite is compliance" "project_auth_compliance.md" \
    "Body B." "0.91"
  _seed_proposal "01LISTACCEPTED0000000000000" \
    "user" "Already accepted" "user_old.md" \
    "Body C." "0.7" "accepted"

  run librarian_cli_list "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  # Header counts only pending entries (2 of 3).
  [[ "$output" == *"2 pending proposal"* ]]
  # Both pending titles surface.
  [[ "$output" == *"Prefer functional patterns"* ]]
  [[ "$output" == *"Auth rewrite is compliance"* ]]
  # Pending rows include full IDs that can be used with show/accept/reject/defer.
  [[ "$output" == *"01LISTPENDINGA000000000000"* ]]
  [[ "$output" == *"01LISTPENDINGB000000000000"* ]]
  # Accepted entry does NOT appear in the list output.
  [[ "$output" != *"Already accepted"* ]]
}

@test "show renders provenance + body for an existing proposal" {
  _seed_proposal "01SHOWPROPOSAL0000000000000" \
    "feedback" "Some title" "feedback_x.md" \
    "Body of the memory."

  run librarian_cli_show "01SHOWPROPOSAL0000000000000" "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"01SHOWPROPOSAL0000000000000"* ]]
  [[ "$output" == *"type:                 feedback"* ]]
  [[ "$output" == *"filename:             feedback_x.md"* ]]
  [[ "$output" == *"classifier_confidence: 0.82"* ]]
  [[ "$output" == *"Body of the memory."* ]]
}

@test "show fails clean on an unknown proposal id" {
  run librarian_cli_show "01NOSUCHPROPOSAL00000000000" "$PROJECT_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "accept writes a memory file with provenance frontmatter" {
  _seed_proposal "01ACCEPTPROPOSAL000000000000" \
    "feedback" "Prefer functional patterns" "feedback_functional.md" \
    "User prefers functional patterns.

**Why:** Stated explicitly.
**How to apply:** Default to plain functions."

  run librarian_cli_accept "01ACCEPTPROPOSAL000000000000" "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Accepted."* ]]

  local out_file="${MEM_DIR}/feedback_functional.md"
  [ -f "$out_file" ]

  # Frontmatter records who promoted it, when, and from where.
  grep -q "^source: librarian$" "$out_file"
  grep -q "^type: feedback$" "$out_file"
  grep -q "^name: Prefer functional patterns$" "$out_file"
  grep -q "^classifier_confidence: 0.82$" "$out_file"
  grep -q "^promoted_at: " "$out_file"
  # Body survives in full.
  grep -q "Default to plain functions" "$out_file"
}

@test "accept appends to MEMORY.md and creates it if missing" {
  _seed_proposal "01ACCEPTINDEX000000000000000" \
    "project" "Auth rewrite is compliance" "project_auth_compliance.md" \
    "Compliance-driven."

  [ ! -f "${MEM_DIR}/MEMORY.md" ]

  run librarian_cli_accept "01ACCEPTINDEX000000000000000" "$PROJECT_REPO"
  [ "$status" -eq 0 ]

  [ -f "${MEM_DIR}/MEMORY.md" ]
  grep -F -q "(project_auth_compliance.md)" "${MEM_DIR}/MEMORY.md"
  grep -F -q "Auth rewrite is compliance" "${MEM_DIR}/MEMORY.md"
}

@test "accept marks the proposal accepted and emits librarian.proposal.accepted" {
  _seed_proposal "01ACCEPTEVENT000000000000000" \
    "user" "User role" "user_role.md" "Body."

  run librarian_cli_accept "01ACCEPTEVENT000000000000000" "$PROJECT_REPO"
  [ "$status" -eq 0 ]

  # Proposal file flipped to accepted.
  local proposal_path="${LIBRARIAN_DIR}/proposals/01ACCEPTEVENT000000000000000.json"
  jq -e '.status == "accepted"' "$proposal_path" >/dev/null
  jq -e '.final_filename == "user_role.md"' "$proposal_path" >/dev/null

  # Event landed in the canonical events log.
  [ -f "$ONLOOKER_EVENTS_LOG" ]
  grep -q '"event_type":"librarian.proposal.accepted"' "$ONLOOKER_EVENTS_LOG"
  grep '"event_type":"librarian.proposal.accepted"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.proposal_id == "01ACCEPTEVENT000000000000000" and .payload.final_filename == "user_role.md"' >/dev/null
}

@test "accept refuses path-traversal filenames and writes nothing" {
  _seed_proposal "01ACCEPTUNSAFE00000000000000" \
    "user" "Bad filename" "../escape.md" "Body."

  run librarian_cli_accept "01ACCEPTUNSAFE00000000000000" "$PROJECT_REPO"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to write memory file."* ]]

  # No memory file written anywhere under MEM_DIR or its parent.
  [ ! -f "${MEM_DIR}/../escape.md" ]
  [ ! -f "${MEM_DIR}/escape.md" ]

  # Proposal stays pending so a reviewer can resolve it manually.
  local proposal_path="${LIBRARIAN_DIR}/proposals/01ACCEPTUNSAFE00000000000000.json"
  jq -e '.status == "pending"' "$proposal_path" >/dev/null
}

@test "reject writes a tombstone and marks the proposal rejected" {
  local body="This is the body whose hash anchors the tombstone."
  _seed_proposal "01REJECTPROPOSAL00000000000" \
    "feedback" "Some idea" "feedback_some_idea.md" "$body"

  run librarian_cli_reject "01REJECTPROPOSAL00000000000" "stale guidance" "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rejected"* ]]
  [[ "$output" == *"stale guidance"* ]]

  # Proposal status now rejected with the reason captured.
  local proposal_path="${LIBRARIAN_DIR}/proposals/01REJECTPROPOSAL00000000000.json"
  jq -e '.status == "rejected"' "$proposal_path" >/dev/null
  jq -e '.reason == "stale guidance"' "$proposal_path" >/dev/null

  # Tombstone file present, keyed on the body hash.
  local expected_hash
  expected_hash=$(librarian_body_hash "$body")
  [ -n "$expected_hash" ]
  [ -f "${LIBRARIAN_DIR}/tombstones/${expected_hash}.json" ]
  librarian_storage_has_tombstone "$PROJECT_KEY" "$expected_hash"

  # Both events fired.
  grep -q '"event_type":"librarian.proposal.rejected"' "$ONLOOKER_EVENTS_LOG"
  grep -q '"event_type":"librarian.tombstone.created"' "$ONLOOKER_EVENTS_LOG"
  grep '"event_type":"librarian.proposal.rejected"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.reason == "stale guidance"' >/dev/null
  grep '"event_type":"librarian.tombstone.created"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e --arg h "$expected_hash" '.payload.body_hash == $h' >/dev/null
}

@test "defer stamps the proposal but leaves it pending" {
  _seed_proposal "01DEFERPROPOSAL000000000000" \
    "user" "Maybe later" "user_maybe.md" "Body."

  run librarian_cli_defer "01DEFERPROPOSAL000000000000" "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deferred"* ]]

  local proposal_path="${LIBRARIAN_DIR}/proposals/01DEFERPROPOSAL000000000000.json"
  jq -e '.status == "pending"' "$proposal_path" >/dev/null
  jq -e '.deferred == true' "$proposal_path" >/dev/null

  # Defer should NOT touch the memory store.
  [ ! -d "$MEM_DIR" ] || [ -z "$(ls -A "$MEM_DIR" 2>/dev/null)" ]
}

@test "status reports counts across pending, accepted, and rejected" {
  _seed_proposal "01STATUSPENDING0000000000000" "user" "P" "user_p.md" "p" "0.7" "pending"
  _seed_proposal "01STATUSACCEPTED000000000000" "user" "A" "user_a.md" "a" "0.7" "accepted"
  _seed_proposal "01STATUSREJECTED000000000000" "user" "R" "user_r.md" "r" "0.7" "rejected"

  run librarian_cli_status "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pending: 1"* ]]
  [[ "$output" == *"accepted: 1"* ]]
  [[ "$output" == *"rejected: 1"* ]]
}

@test "librarian_cli dispatch routes to the right subcommand" {
  _seed_proposal "01DISPATCH00000000000000000" \
    "user" "Dispatch test" "user_dispatch.md" "Body."

  # Unknown action returns exit 2.
  run librarian_cli "explode"
  [ "$status" -eq 2 ]

  # Known action delegates correctly.
  run librarian_cli "show" "01DISPATCH00000000000000000" "$PROJECT_REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Dispatch test"* ]]
}

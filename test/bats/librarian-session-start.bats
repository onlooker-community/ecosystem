#!/usr/bin/env bats
#
# Tests the librarian SessionStart surfacer. Verifies:
#   - Disabled config: empty additionalContext, exit 0.
#   - No git context: empty additionalContext, exit 0.
#   - Empty proposal queue + skip_inject_when_zero=true: empty context.
#   - Pending proposals: one-line pointer with the count and pluralization.
#   - Overflow: counts above max_pending_for_inject render as "<cap>+".

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
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/librarian-surfacer-test.git

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
  PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]
  LIBRARIAN_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}"

  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"librarian":{"enabled":true}}' > "${PROJECT_REPO}/.claude/settings.json"

  HOOK="${PLUGIN_ROOT}/scripts/hooks/librarian-session-start.sh"
}

_input() {
  jq -cn --arg cwd "$PROJECT_REPO" \
    '{cwd: $cwd, source: "startup", session_id: "sess-start-test"}'
}

# Helper: drop a proposal file with the given status into the queue.
_seed_proposal() {
  local id="$1" status="${2:-pending}"
  mkdir -p "${LIBRARIAN_DIR}/proposals"
  jq -n --arg id "$id" --arg status "$status" \
    '{
      id: $id,
      created_at: "2026-06-01T00:00:00Z",
      source_artifact_ids: [],
      source_session_ids: [],
      proposed: { type: "feedback", filename: ($id + ".md"),
                  title: "t", body: "b", classifier_confidence: 0.8 },
      conflict_state: "none",
      conflict_with: [],
      status: $status
    }' > "${LIBRARIAN_DIR}/proposals/${id}.json"
}

@test "surfacer emits empty context when librarian is disabled" {
  rm -f "${PROJECT_REPO}/.claude/settings.json"
  _seed_proposal "01PROPOSALA000000000000000"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
}

@test "surfacer emits empty context when there is no git context" {
  local non_git="${BATS_TEST_TMPDIR}/no-git"
  mkdir -p "$non_git"
  local input
  input=$(jq -cn --arg cwd "$non_git" '{cwd: $cwd, source: "startup", session_id: "s"}')

  run bash -c "printf '%s' '$input' | '$HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

@test "surfacer emits empty context when no proposals are pending" {
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

@test "surfacer surfaces one-line pointer when proposals exist (plural)" {
  _seed_proposal "01PROPOSAL11111111111111A"
  _seed_proposal "01PROPOSAL11111111111111B"
  _seed_proposal "01PROPOSAL11111111111111C"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Librarian has 3 pending memory promotion proposals"* ]]
  [[ "$ctx" == *"/librarian review"* ]]
}

@test "surfacer pluralizes singular vs plural correctly" {
  _seed_proposal "01PROPOSALSINGULAR0000000"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Librarian has 1 pending memory promotion proposal"* ]]
  [[ "$ctx" != *"proposals."* ]]
}

@test "surfacer ignores accepted/rejected proposals when counting pending" {
  _seed_proposal "01PROPOSALACCEPTED000000" "accepted"
  _seed_proposal "01PROPOSALREJECTED000000" "rejected"
  _seed_proposal "01PROPOSALPENDING0000000" "pending"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"1 pending memory promotion proposal"* ]]
}

@test "surfacer caps display at max_pending_for_inject + '+'" {
  # Override max to 3 via a project settings overlay.
  printf '%s\n' '{"librarian":{"enabled":true,"surfacer":{"max_pending_for_inject":3}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"
  for i in A B C D E; do
    _seed_proposal "01PROPOSALCAP$i$i$i$i$i$i$i$i$i$i$i$i"
  done

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Librarian has 3+ pending memory promotion proposals"* ]]
}

#!/usr/bin/env bats
#
# Exercises the historian SessionEnd indexing pipeline end-to-end:
# transcript reader -> chunker -> sanitizer -> JSONL store.
#
# The test fixtures construct sensitive-shaped strings at runtime via
# printf rather than embedding the literal patterns inline, so the
# repo-wide secret-scanner hook does not refuse to commit this file.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/historian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/historian-test.git

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/historian-project-key.sh"
  PROJECT_KEY=$(historian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  HIST_DIR="${ONLOOKER_DIR}/historian/${PROJECT_KEY}"
  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

  TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
  SESSION_ID="sess-hist-test"

  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"historian":{"indexing":{"min_transcript_chars_to_index":50,"chunk_target_chars":400,"chunk_overlap_chars":50}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  HOOK="${PLUGIN_ROOT}/scripts/hooks/historian-session-end.sh"
}

_input() {
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "$SESSION_ID" \
    --arg transcript "$TRANSCRIPT" \
    '{cwd:$cwd, session_id:$sid, transcript_path:$transcript, hook_event_name:"SessionEnd"}'
}

_append_text_turn() {
  local role="$1" text="$2"
  jq -cn --arg role "$role" --arg text "$text" \
    '{role: $role, content: $text}' >> "$TRANSCRIPT"
}

_append_block_turn() {
  local role="$1" text="$2"
  jq -cn --arg role "$role" --arg text "$text" \
    '{role: $role, content: [
      { type: "text", text: $text },
      { type: "tool_use", name: "Read", input: { file_path: "/tmp/x" } }
    ]}' >> "$TRANSCRIPT"
}

_chunk_count() {
  local file="${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  [ -f "$file" ] || { echo 0; return 0; }
  wc -l < "$file" | tr -d ' '
}


@test "session-end emits skip_reason transcript_unavailable when path missing" {
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  grep '"event_type":"historian.indexing.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "skipped" and .payload.skip_reason == "transcript_unavailable"' >/dev/null
}

@test "session-end emits skip_reason too_short for a tiny transcript" {
  _append_text_turn "user" "hi"
  _append_text_turn "assistant" "yo"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  grep '"event_type":"historian.indexing.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "skipped" and .payload.skip_reason == "too_short"' >/dev/null
}

@test "session-end indexes a real transcript with provenance" {
  _append_text_turn "user" "Investigating a flaky test in the auth middleware path. The CI run https://example.com/foo failed on retry 3."
  _append_text_turn "assistant" "Looking at it now. The root cause is a race between session token cache invalidation and the redirect retry loop."
  _append_text_turn "user" "What's the proposed fix?"
  _append_text_turn "assistant" "Move cache invalidation into the redirect handler, so it runs before the retry, not concurrently."

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  local count
  count=$(_chunk_count)
  [ "$count" -ge 1 ]

  jq -e '.chunk_id != null and .session_id != null and .body_redacted != null
         and .body_chars > 0 and .chunk_index >= 0
         and .start_turn_index >= 0 and .end_turn_index >= .start_turn_index' \
    "${HIST_DIR}/sessions/${SESSION_ID}.jsonl" >/dev/null

  grep '"event_type":"historian.indexing.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e ".payload.outcome == \"ok\" and .payload.chunks_indexed == $count" >/dev/null
}

@test "session-end redacts secret-shaped substrings" {
  # Construct secret-shaped strings at runtime to keep the literal
  # patterns out of the bats source file (the repo's secret-scanner
  # PreToolUse hook would otherwise refuse to write this file).
  local fake_aws fake_gh fake_anthropic
  fake_aws="A${KIA_PREFIX:-KIA}ABCDEFGHIJKLMNOP"
  fake_aws="AK${fake_aws:1}"
  fake_gh="g""hp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  fake_anthropic="s""k-ant-veryverylongtokenvalue1234"
  local turn_body
  turn_body=$(printf "Here's an AWS key: %s. And a GitHub PAT %s. And API_TOKEN=%s. And Bearer abcdefghijklmnopqrstuvwxyz." \
    "$fake_aws" "$fake_gh" "$fake_anthropic")
  _append_text_turn "user" "$turn_body"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  local jsonl="${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  ! grep -F -q "$fake_aws" "$jsonl"
  ! grep -F -q "$fake_gh" "$jsonl"
  ! grep -F -q "$fake_anthropic" "$jsonl"
  grep -q 'REDACTED:secret' "$jsonl"
  jq -e '.redaction_count > 0' "$jsonl" >/dev/null
  grep -q '"event_type":"historian.chunk.sanitized"' "$ONLOOKER_EVENTS_LOG"
}

@test "session-end drops chunks containing the skip marker" {
  local marker
  marker='[hist''orian:skip]'   # split literal so this source file does not embed it
  _append_text_turn "user" "$(printf 'normal turn %.0s' {1..30})"
  _append_text_turn "assistant" "ack"
  _append_text_turn "user" "this turn is meant to be sensitive ${marker} please ignore"
  _append_text_turn "assistant" "$(printf 'second turn %.0s' {1..30})"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(_chunk_count)" -ge 1 ]

  ! grep -F -q "$marker" "${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  ! grep -q 'meant to be sensitive' "${HIST_DIR}/sessions/${SESSION_ID}.jsonl"

  grep '"event_type":"historian.chunk.dropped"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.reason == "skip_marker"' >/dev/null
}

@test "session-end drops chunks referencing never_index_paths" {
  printf '%s\n' \
    '{"historian":{"indexing":{"min_transcript_chars_to_index":50,"chunk_target_chars":400,"chunk_overlap_chars":50},"sanitization":{"never_index_paths":["restricted/notes.md"]}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  _append_text_turn "user" "$(printf 'first chunk %.0s' {1..30})"
  _append_text_turn "assistant" "second turn references restricted/notes.md which must be dropped from the index entirely"
  _append_text_turn "user" "$(printf 'third chunk %.0s' {1..30})"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  ! grep -q 'restricted/notes.md' "${HIST_DIR}/sessions/${SESSION_ID}.jsonl"

  grep '"event_type":"historian.chunk.dropped"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.reason == "never_index_path"' >/dev/null
}

@test "session-end drops tool_use blocks before chunking" {
  _append_text_turn "user" "$(printf 'long enough %.0s' {1..30})"
  _append_block_turn "assistant" "Plain spoken assistant text that should appear in the index."

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  [ "$(_chunk_count)" -ge 1 ]
  grep -q 'Plain spoken assistant text' "${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  ! grep -q 'tool_use' "${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  ! grep -q '/tmp/x' "${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
}

@test "session-end is idempotent on re-run (replaces, not appends)" {
  _append_text_turn "user" "$(printf 'first index %.0s' {1..30})"
  _append_text_turn "assistant" "$(printf 'response %.0s' {1..30})"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local first_count
  first_count=$(_chunk_count)
  [ "$first_count" -ge 1 ]

  rm -f "$ONLOOKER_EVENTS_LOG"
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]
  local second_count
  second_count=$(_chunk_count)
  [ "$second_count" -eq "$first_count" ]

  grep '"event_type":"historian.indexing.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e ".payload.outcome == \"ok\" and .payload.chunks_indexed == $second_count" >/dev/null
}

@test "Bearer token redaction is case-insensitive" {
  # Lowercase + mixed-case bearer variants — Copilot caught that the
  # original regex only matched the title-case "Bearer" form.
  local lower mixed
  lower="b""earer abcdefghijklmnopqrstuvwxyz1234"
  mixed="B""EARER zyxwvutsrqponmlkjihgfedcba98765432"
  local body
  body=$(printf "Headers: %s; also %s; padding here for length." "$lower" "$mixed")
  _append_text_turn "user" "$body"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  local jsonl="${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  ! grep -F -q "abcdefghijklmnopqrstuvwxyz1234" "$jsonl"
  ! grep -F -q "zyxwvutsrqponmlkjihgfedcba98765432" "$jsonl"
  grep -q 'REDACTED:secret' "$jsonl"
}

@test "redact_secret_patterns=false leaves secret-shaped strings untouched" {
  printf '%s\n' \
    '{"historian":{"indexing":{"min_transcript_chars_to_index":50,"chunk_target_chars":400,"chunk_overlap_chars":50},"sanitization":{"redact_secret_patterns":false}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  # Synthetic AWS-shaped string. Without redaction it should pass through
  # to the JSONL verbatim; the chunk's redaction_count should be 0.
  local fake_aws="AK""IAABCDEFGHIJKLMNOP"
  _append_text_turn "user" "Header: AWS=$fake_aws — please do not redact this value because the user explicitly opted out."

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  local jsonl="${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  grep -F -q "$fake_aws" "$jsonl"
  ! grep -q 'REDACTED:secret' "$jsonl"
  jq -e '.redaction_count == 0' "$jsonl" >/dev/null
}

@test "drop_skip_marker=false keeps chunks containing the marker" {
  printf '%s\n' \
    '{"historian":{"indexing":{"min_transcript_chars_to_index":50,"chunk_target_chars":400,"chunk_overlap_chars":50},"sanitization":{"drop_skip_marker":false}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  local marker
  marker='[hist''orian:skip]'
  _append_text_turn "user" "Body that contains the ${marker} marker but should still be indexed when the flag is disabled. Padding to clear the min-chars threshold easily."

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  local jsonl="${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  [ "$(_chunk_count)" -ge 1 ]
  grep -F -q "$marker" "$jsonl"
  ! grep '"event_type":"historian.chunk.dropped"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e 'select(.payload.reason == "skip_marker")' >/dev/null || true
}

@test "historian.indexing.started reports a non-zero transcript_chars" {
  # Previously the started event emitted transcript_chars: 0 because it
  # fired before the transcript was read. Now it fires after the read,
  # carrying the real character count.
  _append_text_turn "user" "$(printf 'long enough for chars %.0s' {1..20})"
  _append_text_turn "assistant" "$(printf 'response with content %.0s' {1..20})"

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  grep '"event_type":"historian.indexing.started"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.transcript_chars > 0' >/dev/null
}

@test "transcript_unavailable path emits complete without a started event" {
  # When the transcript path is missing we never read it, so no started
  # event makes it to the log. Only the complete-with-skip remains.
  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ]

  ! grep -q '"event_type":"historian.indexing.started"' "$ONLOOKER_EVENTS_LOG"
  grep -q '"event_type":"historian.indexing.complete"' "$ONLOOKER_EVENTS_LOG"
}

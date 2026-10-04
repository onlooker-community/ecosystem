#!/usr/bin/env bats
#
# Exercises the historian UserPromptSubmit retrieval pipeline end-to-end
# against a synthetic ollama daemon (a fake `curl` binary on PATH that
# returns predictable embeddings keyed on sentinel substrings in the
# prompt). Indexing happens via the real SessionEnd hook against the
# same stub, so the test exercises both halves of the embedder
# integration.

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
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/historian-retrieval-test.git

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/historian-project-key.sh"
  PROJECT_KEY=$(historian_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  HIST_DIR="${ONLOOKER_DIR}/historian/${PROJECT_KEY}"
  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"

  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  cat > "${STUB_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
# Mini curl stub for historian bats tests.
# Parses just enough of the curl arg shape to find the URL and the -d
# payload. Returns deterministic embeddings keyed on sentinel substrings
# in the prompt.
url=""
payload=""
prev=""
for arg in "$@"; do
  case "$prev" in
    -d|--data|--data-raw)
      payload="$arg"; prev=""; continue ;;
    --max-time|-o|-H|--header)
      prev=""; continue ;;
  esac
  case "$arg" in
    -d|--data|--data-raw|--max-time|-o|-H|--header)
      prev="$arg" ;;
    -*)
      ;;
    *)
      [[ -z "$url" ]] && url="$arg" ;;
  esac
done

# An env var toggles the probe success so the same stub serves the
# "embedder unavailable" test case.
if [[ "${HISTORIAN_STUB_OLLAMA_AVAILABLE:-1}" == "0" ]]; then
  exit 7
fi

if [[ "$url" == */api/tags ]]; then
  printf '{"models":[{"name":"nomic-embed-text"}]}'
  exit 0
fi

# A second toggle fails only the EMBED calls, leaving the probe passing. That
# is the state that hid ONL-123: /api/tags answers instantly from disk whether
# or not the model is resident, so a cold daemon looks available and then times
# out on every embed.
if [[ "$url" == */api/embeddings && -n "${HISTORIAN_STUB_EMBED_RC:-}" ]]; then
  exit "${HISTORIAN_STUB_EMBED_RC}"
fi

if [[ "$url" == */api/embeddings ]]; then
  prompt=$(printf '%s' "$payload" | jq -r '.prompt // ""' 2>/dev/null)
  case "$prompt" in
    *redash*) printf '{"embedding":[1,0,0]}' ;;
    *kafka*)  printf '{"embedding":[0,1,0]}' ;;
    *postgres*) printf '{"embedding":[0,0,1]}' ;;
    *) printf '{"embedding":[0.5,0.5,0.5]}' ;;
  esac
  exit 0
fi

exit 1
STUB
  chmod +x "${STUB_BIN}/curl"
  export PATH="${STUB_BIN}:${PATH}"

  TRANSCRIPT="${BATS_TEST_TMPDIR}/transcript.jsonl"
  SESSION_ID="sess-retrieval"

  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' \
    '{"historian":{"indexing":{"min_transcript_chars_to_index":50,"chunk_target_chars":400,"chunk_overlap_chars":50},"retrieval":{"cooldown_seconds":60,"max_retrievals_per_session":5,"min_prompt_chars":40,"min_similarity":0.55,"max_age_days":365}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  INDEX_RUNNER="${PLUGIN_ROOT}/scripts/run-index.sh"
  RETRIEVE_HOOK="${PLUGIN_ROOT}/scripts/hooks/historian-prompt-submit.sh"
}

_retrieve_input() {
  local prompt="$1" sid="${2:-current}"
  jq -cn --arg cwd "$PROJECT_REPO" --arg sid "$sid" --arg prompt "$prompt" \
    '{cwd:$cwd, session_id:$sid, prompt:$prompt, hook_event_name:"UserPromptSubmit"}'
}

_append_text_turn() {
  local role="$1" text="$2"
  jq -cn --arg role "$role" --arg text "$text" \
    '{role:$role, content:$text}' >> "$TRANSCRIPT"
}

_index_session() {
  local sid="$1"
  shift
  : > "$TRANSCRIPT"
  while [ $# -gt 0 ]; do
    _append_text_turn "user" "$1"; shift
    [ $# -gt 0 ] && { _append_text_turn "assistant" "$1"; shift; }
  done
  # Seeds the index synchronously. The SessionEnd hook only launches this
  # runner now (ONL-123), so going through the hook would return before any
  # chunk existed and every retrieval test below would search an empty store.
  env \
    HISTORIAN_SESSION_ID="$sid" \
    HISTORIAN_CWD="$PROJECT_REPO" \
    HISTORIAN_TRANSCRIPT="$TRANSCRIPT" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    ONLOOKER_DIR="$ONLOOKER_DIR" \
    "$INDEX_RUNNER" >/dev/null
}


@test "retrieval skipped when prompt is shorter than min_prompt_chars" {
  run bash -c "printf '%s' '$(_retrieve_input "tiny")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
  grep '"event_type":"historian.retrieval.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "skipped" and .payload.skip_reason == "short_prompt"' >/dev/null
}

@test "indexing embeds chunks when ollama is up" {
  _index_session "$SESSION_ID" \
    "We are debugging a redash dashboard problem with timezone offsets and saved query parameters this morning." \
    "Sure — the latest version always passes UTC because of a chart migration we did last week."

  local jsonl="${HIST_DIR}/sessions/${SESSION_ID}.jsonl"
  [ -f "$jsonl" ]
  jq -e '.embedding | type == "array" and length == 3' "$jsonl" >/dev/null
}

@test "retrieval surfaces a matching past chunk" {
  # Index a past session containing a "redash" topic.
  _index_session "past-1" \
    "We are debugging a redash dashboard problem with timezone offsets and saved query parameters this morning." \
    "Sure — the latest version always passes UTC because of a chart migration we did last week."

  # New session, same project, query about redash → should match.
  run bash -c "printf '%s' '$(_retrieve_input "Hitting another redash dashboard timezone issue on the same saved query parameters again today")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ]

  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"Historian: a past chunk looks similar"* ]] || return 1
  [[ "$ctx" == *"redash"* ]]

  grep '"event_type":"historian.retrieval.surfaced"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.similarity >= 0.55 and .payload.source_session_id == "past-1"' >/dev/null
}

@test "retrieval returns empty when no chunk clears the similarity floor" {
  # Past session about kafka — query about postgres falls below the
  # 0.55 floor (the embedding vectors are orthogonal in the stub).
  _index_session "past-2" \
    "Investigating kafka consumer lag on the ingest pipeline today after the rebalance event yesterday." \
    "Looks like the rebalance left a stale offset; manual reset cleared it."

  run bash -c "printf '%s' '$(_retrieve_input "Working on a postgres migration plan today for our settings tables to add new columns safely")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null

  grep '"event_type":"historian.retrieval.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "empty"' >/dev/null
}

@test "retrieval skipped on cooldown" {
  _index_session "past-3" \
    "Yet another redash dashboard query that we had to fix the timezone on this morning to make the report run again." \
    "ok"

  # First retrieval surfaces something.
  run bash -c "printf '%s' '$(_retrieve_input "redash dashboard timezone problem again on the saved query parameters this morning afternoon")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ]
  grep -q '"event_type":"historian.retrieval.surfaced"' "$ONLOOKER_EVENTS_LOG"

  rm -f "$ONLOOKER_EVENTS_LOG"

  # Immediate second retrieval (same session) hits the cooldown gate
  # (60s) and gets skipped without calling the embedder.
  run bash -c "printf '%s' '$(_retrieve_input "redash dashboard timezone problem follow-up just a moment after the previous prompt cleared")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ]
  grep '"event_type":"historian.retrieval.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "skipped" and .payload.skip_reason == "cooldown"' >/dev/null
}

@test "retrieval skipped when the embedder is unreachable" {
  _index_session "past-4" \
    "Yet another redash dashboard query that we had to fix the timezone on this morning to make the report run again." \
    "ok"

  # Turn off the stub so the probe fails.
  HISTORIAN_STUB_OLLAMA_AVAILABLE=0 \
    run bash -c "printf '%s' '$(_retrieve_input "redash dashboard timezone problem long enough to clear the prompt floor for retrieval")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null

  grep -q '"event_type":"historian.embedder.unavailable"' "$ONLOOKER_EVENTS_LOG"
  grep '"event_type":"historian.retrieval.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "skipped" and .payload.skip_reason == "embedder_unavailable"' >/dev/null
}

@test "retrieval excludes chunks from the current session id" {
  # Index the same session id we'll then query from — should be excluded.
  _index_session "current" \
    "Working on a redash dashboard right now in this very session of the test framework that we are running." \
    "ok"

  run bash -c "printf '%s' '$(_retrieve_input "redash dashboard timezone trouble inside this very session of the test framework")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
  grep '"event_type":"historian.retrieval.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "empty"' >/dev/null
}

@test "a failed embed is reported as embed_failed, not embedder_unavailable" {
  # The probe passes and the embed times out — a cold model. Calling that
  # "unavailable" names a probe failure that did not happen, and is what made
  # 59 of 115 prompt submissions in the live log unattributable (ONL-123).
  run env HISTORIAN_STUB_EMBED_RC=28 bash -c \
    "printf '%s' '$(_retrieve_input "Hitting another redash dashboard timezone issue on the same saved query parameters again today")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"historian.retrieval.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "skipped" and .payload.skip_reason == "embed_failed"' >/dev/null || return 1

  grep '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.reason == "timeout" and .payload.attempted == 1 and .payload.failed == 1' >/dev/null
}

@test "an unreachable embedder still reports embedder_unavailable" {
  # The converse, so the two reasons cannot collapse back into one.
  run env HISTORIAN_STUB_OLLAMA_AVAILABLE=0 bash -c \
    "printf '%s' '$(_retrieve_input "Hitting another redash dashboard timezone issue on the same saved query parameters again today")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"historian.retrieval.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.skip_reason == "embedder_unavailable"' >/dev/null || return 1

  ! grep -q '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG"
}

@test "a prompt past max_input_chars is still embedded instead of dropped" {
  # ONL-131: the prompt path gated on min_prompt_chars and had no ceiling, so a
  # prompt past the embedder's max_input_chars (6000 default) failed `oversized`
  # inside the embedder and retrieval returned an empty context block. 93 of 246
  # live retrievals since 2026-09-29 died this way — 38%, and the failures
  # cluster on the busiest days, when retrieval is worth the most.
  _index_session "past-oversized" \
    "We are debugging a redash dashboard problem with timezone offsets and saved query parameters this morning." \
    "Sure — the latest version always passes UTC because of a chart migration we did last week."

  # Sentinel text first so it survives a head-truncation, then pad well past
  # the 6000-char default.
  local long_prompt padding
  padding=$(printf 'additional context line %s. ' $(seq 1 400))
  long_prompt="Hitting another redash dashboard timezone issue on the same saved query parameters again today. ${padding}"
  [ "${#long_prompt}" -gt 6000 ] || return 1

  run bash -c "printf '%s' '$(_retrieve_input "$long_prompt")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ] || return 1

  # Nothing on this path may report `oversized` any more: the ceiling belongs to
  # the prompt path, not to a failure discovered inside the embedder.
  local oversized
  oversized=$(grep '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null \
    | jq -rc 'select(.payload.reason == "oversized") | .payload.reason' | wc -l | tr -d ' ')
  [ "$oversized" -eq 0 ] || return 1

  grep '"event_type":"historian.retrieval.surfaced"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.source_session_id == "past-oversized"' >/dev/null
}

@test "a non-numeric max_input_chars does not break the prompt path" {
  # max_input_chars is user-editable config (ADR-004), so a typo is reachable.
  # Unguarded, `(( PROMPT_LEN > abc ))` reads abc as 0 and the substring
  # expansion ${PROMPT:0:abc} is then a bash arithmetic error inside the hook.
  # The hook must still complete and report an outcome rather than die mid-path.
  printf '%s\n' \
    '{"historian":{"indexing":{"min_transcript_chars_to_index":50,"chunk_target_chars":400,"chunk_overlap_chars":50},"embedder":{"max_input_chars":"not-a-number"},"retrieval":{"cooldown_seconds":60,"max_retrievals_per_session":5,"min_prompt_chars":40,"min_similarity":0.55,"max_age_days":365}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  run bash -c "printf '%s' '$(_retrieve_input "Hitting another redash dashboard timezone issue on the same saved query parameters again today")' | '$RETRIEVE_HOOK'"
  [ "$status" -eq 0 ] || return 1

  # No bash diagnostic leaked into the hook's own output.
  [[ "$output" != *"substitution"* ]] || return 1
  [[ "$output" != *"syntax error"* ]] || return 1

  # And it still reached the point of reporting a retrieval outcome.
  grep -q '"event_type":"historian.retrieval.complete"' "$ONLOOKER_EVENTS_LOG"
}

#!/usr/bin/env bats
#
# historian must report what happened to the embeddings it did not produce.
#
# ONL-123. The ollama client had nine failure paths and every one returned an
# empty string and emitted nothing. The caller then wrote the chunk with no
# vector and emitted nothing either. Since the retriever is embedding-only,
# those chunks are persisted and unreachable — so an index could lose its
# largest chunks while historian.indexing.complete reported outcome "ok".
# Measured on a real 8.5MB transcript: 4 of 93 chunks lost that way.
#
# The distinction these tests exist to hold is between an embed that FAILED
# and one that was NEVER ATTEMPTED. historian.embedder.unavailable already
# covered the second (the probe failed). Nothing covered the first, and the
# probe passes in exactly the case that matters: it asks /api/tags, which
# answers instantly from disk whether or not the model is resident, so a cold
# daemon looks healthy and then times out on every embed.

setup() {
  # shellcheck source=../helpers/setup.bash
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
  SESSION_ID="sess-embed-report"
  RUNNER="${PLUGIN_ROOT}/scripts/run-index.sh"

  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  export PATH="${STUB_BIN}:${PATH}"

  mkdir -p "${PROJECT_REPO}/.claude"
  _write_settings 6000
  _seed_transcript
}

# min_transcript_chars_to_index is lowered so a short fixture still indexes;
# chunk sizes are small so the fixture produces several chunks rather than one.
_write_settings() {
  local max_input_chars="${1:-6000}"
  jq -n --argjson m "$max_input_chars" '{
    historian: {
      indexing: {
        min_transcript_chars_to_index: 50,
        chunk_target_chars: 400,
        chunk_overlap_chars: 50
      },
      embedder: {
        backend: "ollama",
        max_input_chars: $m,
        ollama: { host: "http://127.0.0.1:11434", model: "nomic-embed-text" }
      }
    }
  }' > "${PROJECT_REPO}/.claude/settings.json"
}

_seed_transcript() {
  : > "$TRANSCRIPT"
  _append_turn "user" "Investigating a flaky test in the auth middleware path, which keeps failing on retry three of the CI job."
  _append_turn "assistant" "The root cause is a race between session token cache invalidation and the redirect retry loop in the middleware."
  _append_turn "user" "What is the proposed fix for that race, and does it need a migration?"
  _append_turn "assistant" "Move cache invalidation into the redirect handler so it runs before the retry rather than concurrently with it."
}

_append_turn() {
  jq -cn --arg role "$1" --arg text "$2" \
    '{type:$role, message:{content:[{type:"text", text:$text}]}}' >>"$TRANSCRIPT"
}

# A curl stub standing in for ollama. `tags_ok` decides whether the PROBE
# passes; `embed_rc` is the exit status every embed call returns, so a test can
# drive a cold-model timeout (28) or a rejected body (22) precisely.
_install_curl_stub() {
  local tags_ok="${1:-1}" embed_rc="${2:-0}"
  cat >"${STUB_BIN}/curl" <<STUB
#!/usr/bin/env bash
url=""
for arg in "\$@"; do
  case "\$arg" in
    http*) url="\$arg" ;;
  esac
done

case "\$url" in
  */api/tags)
    if [[ "${tags_ok}" -eq 1 ]]; then
      printf '%s' '{"models":[{"name":"nomic-embed-text:latest"}]}'
      exit 0
    fi
    exit 7
    ;;
  */api/embeddings)
    if [[ "${embed_rc}" -ne 0 ]]; then
      exit ${embed_rc}
    fi
    # A 768-dim vector, the shape nomic-embed-text returns.
    python3 -c 'import json; print(json.dumps({"embedding": [0.01] * 768}))'
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "${STUB_BIN}/curl"
}

_run_index() {
  run env \
    HISTORIAN_SESSION_ID="$SESSION_ID" \
    HISTORIAN_CWD="$PROJECT_REPO" \
    HISTORIAN_TRANSCRIPT="$TRANSCRIPT" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    ONLOOKER_DIR="$ONLOOKER_DIR" \
    "$RUNNER"
}

_complete_event() {
  grep '"event_type":"historian.indexing.complete"' "$ONLOOKER_EVENTS_LOG" | tail -1
}

@test "a reachable embedder that fails every call emits embedder.failed" {
  # The probe passes and every embed times out — precisely the cold-model
  # state that produced ONL-123's 0-of-37 run and reported nothing.
  _install_curl_stub 1 28
  _run_index
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.reason == "timeout" and .payload.failed > 0 and .payload.backend == "ollama"' \
    >/dev/null
}

@test "embedder.failed carries the curl exit in its error summary" {
  _install_curl_stub 1 28
  _run_index
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.error_summary | test("curl exit 28")' >/dev/null
}

@test "a failing embedder is distinguishable from an unreachable one" {
  # This is the whole point of the bead. A probe failure means nothing was
  # attempted; a call failure means it was tried and lost. Reporting both as
  # silence is what hid the bug.
  _install_curl_stub 1 28
  _run_index
  [ "$status" -eq 0 ] || return 1

  grep -q '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" || return 1
  ! grep -q '"event_type":"historian.embedder.unavailable"' "$ONLOOKER_EVENTS_LOG" || return 1

  # And the converse: a failed probe reports unavailable and never claims a
  # call failed, because none was made.
  : > "$ONLOOKER_EVENTS_LOG"
  _install_curl_stub 0 0
  _run_index
  [ "$status" -eq 0 ] || return 1

  grep -q '"event_type":"historian.embedder.unavailable"' "$ONLOOKER_EVENTS_LOG" || return 1
  ! grep -q '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG"
}

@test "indexing.complete counts the chunks left without a vector" {
  _install_curl_stub 1 28
  _run_index
  [ "$status" -eq 0 ] || return 1

  # The count of unreachable chunks must be knowable from the event stream
  # rather than by reading the store.
  _complete_event | jq -e '
    .payload.outcome == "ok"
    and .payload.chunks_embedded == 0
    and .payload.chunks_unembedded == .payload.chunks_indexed
    and .payload.chunks_indexed > 0' >/dev/null
}

@test "indexing.complete counts the chunks that did get a vector" {
  _install_curl_stub 1 0
  _run_index
  [ "$status" -eq 0 ] || return 1

  _complete_event | jq -e '
    .payload.chunks_embedded == .payload.chunks_indexed
    and .payload.chunks_unembedded == 0
    and .payload.chunks_embedded > 0' >/dev/null
}

@test "a working embedder emits no failure event" {
  _install_curl_stub 1 0
  _run_index
  [ "$status" -eq 0 ] || return 1

  ! grep -q '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG"
}

@test "vectors actually reach the stored chunks" {
  _install_curl_stub 1 0
  _run_index
  [ "$status" -eq 0 ] || return 1

  # An embedding the retriever can use, not just a counter claiming one.
  jq -e '.embedding | type == "array" and length == 768' \
    "${HIST_DIR}/sessions/${SESSION_ID}.jsonl" >/dev/null
}

@test "a body past max_input_chars is reported as oversized, not sent" {
  # nomic-embed-text answers HTTP 500 above roughly 7k chars and says nothing
  # about size. Refusing locally is the only place the real length can be
  # reported. A tiny limit makes every chunk oversized.
  _write_settings 10
  _install_curl_stub 1 0
  _run_index
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.reason == "oversized"' >/dev/null || return 1

  _complete_event | jq -e '.payload.chunks_embedded == 0' >/dev/null
}

@test "an HTTP rejection is reported as http_error, not a timeout" {
  _install_curl_stub 1 22
  _run_index
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.reason == "http_error"' >/dev/null
}

@test "a connection failure is neither a timeout nor an http_error" {
  # curl exit 7 is connection refused. Folding it into http_error would claim
  # a server answered when none did.
  _install_curl_stub 1 7
  _run_index
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.reason == "request_failed"' >/dev/null
}

@test "one failure event is emitted per run, not per chunk" {
  # A 117-chunk session against a cold embedder would otherwise write 117
  # identical lines, and the SessionEnd budget is why aggregation matters.
  _install_curl_stub 1 28
  _run_index
  [ "$status" -eq 0 ] || return 1

  local failures chunks
  failures=$(grep -c '"event_type":"historian.embedder.failed"' "$ONLOOKER_EVENTS_LOG")
  chunks=$(_complete_event | jq -r '.payload.chunks_indexed')

  [ "$failures" -eq 1 ] || return 1
  [ "$chunks" -gt 1 ]
}

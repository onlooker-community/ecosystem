#!/usr/bin/env bats
#
# The CLI contract and the per-line cost of scribe's extraction path.
#
# Everything here sits past the min_turns gate, which is the only branch the
# rest of the scribe suite drives. That gap is why ecosystem-449.54 survived:
# scribe passed --max-tokens to the claude CLI, which does not accept it, so
# every extraction exited 1 with its stderr discarded. No test ever reached the
# invocation, so nothing noticed that scribe had never distilled anything.
#
# The stub deliberately mimics the real CLI's option handling rather than
# accepting whatever it is handed. A permissive stub would pass against the
# original bug — that is the whole failure mode being guarded here.

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/scribe"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-config.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/scribe-extract.sh"

  # Resolved before any stub dir joins PATH, so shims can delegate to the real
  # binary instead of recursing into themselves.
  REAL_JQ="$(command -v jq)"
  export REAL_JQ

  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"

  ARGV_LOG="${BATS_TEST_TMPDIR}/claude-argv"
  JQ_CALLS="${BATS_TEST_TMPDIR}/jq-calls"
  export ARGV_LOG JQ_CALLS
}

# A claude stub that enforces the real CLI's option surface: anything outside
# the known set is rejected the way the real binary rejects it.
_stub_strict_claude() {
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_LOG"
while (( $# )); do
  case "$1" in
    -p|--print) ;;
    --max-turns|--model) shift ;;
    --*)
      printf "error: unknown option '%s'\n" "$1" >&2
      exit 1
      ;;
    *) ;;
  esac
  shift
done
cat >/dev/null
printf '%s' '{"problem":"p","decisions":["d"],"tradeoffs":["t"],"constraints":["c"],"out_of_scope":["o"],"summary":"s"}'
STUB
  chmod +x "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${PATH}"
}

_transcript() {
  local path="$1" turns="${2:-4}" i
  : > "$path"
  for ((i = 0; i < turns; i++)); do
    printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"question ${i}\"}}" >> "$path"
    printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"answer ${i}\"}}" >> "$path"
  done
}

# ---------------------------------------------------------------------------
# CLI contract
# ---------------------------------------------------------------------------

@test "extraction succeeds against a CLI that rejects unknown options" {
  _stub_strict_claude
  local f="${BATS_TEST_TMPDIR}/t.jsonl"
  _transcript "$f" 4

  run scribe_extract_intent "$f" "claude-haiku-4-5-20251001" 60 2048 0.3 40000
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" | "$REAL_JQ" -e '.summary == "s"' >/dev/null
}

@test "the claude argument vector carries no --max-tokens" {
  _stub_strict_claude
  local f="${BATS_TEST_TMPDIR}/t.jsonl"
  _transcript "$f" 4

  scribe_extract_intent "$f" "claude-haiku-4-5-20251001" 60 2048 0.3 40000 >/dev/null || true

  [ -f "$ARGV_LOG" ] || return 1
  ! grep -qx -- '--max-tokens' "$ARGV_LOG" || return 1
  grep -qx -- '--model' "$ARGV_LOG"
}

@test "a CLI failure leaves the reason somewhere a reader can find it" {
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf "error: something the operator needs to see\n" >&2
exit 1
STUB
  chmod +x "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${PATH}"

  local f="${BATS_TEST_TMPDIR}/t.jsonl"
  _transcript "$f" 4

  local stderr_out
  stderr_out=$(scribe_extract_intent "$f" "m" 60 2048 0.3 40000 2>&1 >/dev/null) || true
  [[ "$stderr_out" == *"something the operator needs to see"* ]] || return 1
  [ -n "$stderr_out" ]
}

# ---------------------------------------------------------------------------
# Per-line cost
# ---------------------------------------------------------------------------

@test "count_turns jq invocations do not scale with transcript length" {
  : > "$JQ_CALLS"
  cat > "${STUB_BIN}/jq" <<'STUB'
#!/usr/bin/env bash
printf 'x' >> "$JQ_CALLS"
exec "$REAL_JQ" "$@"
STUB
  chmod +x "${STUB_BIN}/jq"
  export PATH="${STUB_BIN}:${PATH}"

  local f="${BATS_TEST_TMPDIR}/long.jsonl"
  _transcript "$f" 100   # 200 lines

  run scribe_count_turns "$f"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "100" ] || return 1

  local calls
  calls=$(wc -c < "$JQ_CALLS" | tr -d ' ')
  # One pass over the file, not one process per line. 200 lines must not cost
  # 200+ spawns; a handful is fine, per-line is the defect.
  [ "$calls" -le 4 ]
}

@test "count_turns still ignores tool-result user entries after the rewrite" {
  local f="${BATS_TEST_TMPDIR}/mixed.jsonl"
  printf '%s\n' \
    '{"type":"user","message":{"role":"user","content":"a real prompt"}}' \
    '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"output"}]}}' \
    '{"type":"assistant","message":{"role":"assistant","content":"reply"}}' \
    '{"type":"user","message":{"role":"user","content":"another real prompt"}}' \
    > "$f"

  run scribe_count_turns "$f"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "2" ]
}

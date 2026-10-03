#!/usr/bin/env bats
#
# ONL-126 — curator has to find the typed memory store when the harness does
# not export CLAUDE_PROJECT_ENCODED.
#
# curator_memory_resolve_path bails to empty when the encoding is unknown and
# the template still carries the placeholder. Bailing is right (see
# ecosystem-18f: substituting empty produced ".../projects//memory", a
# real-looking path a caller would mkdir). What was wrong is that the hook
# treated that empty result as "no memory store, nothing to audit" and emitted
# outcome: "ok" with findings_new: 0 — so a scan that never started was
# indistinguishable from a scan that found nothing. Across 20 project dirs on
# the author's machine, curator had produced zero findings since June while
# reporting clean scans every session.
#
# The hook now derives the encoding from cwd the way the substrate does at
# scripts/hooks/memory-recall-tracker.sh:126, and reports an unresolvable
# store as "skipped" rather than "ok".
#
# These live in their own file because curator-session-start.bats deliberately
# bypasses the template — "Bypass the ${CLAUDE_PROJECT_ENCODED} template by
# overriding memory_store_path to an absolute path" — which is exactly why
# resolution through the hook had no coverage. Nothing here overrides
# memory_store_path; the shipped template is the thing under test.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/curator"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
  HOOK="${PLUGIN_ROOT}/scripts/hooks/curator-session-start.sh"

  # The harness normally exports this to hook processes. Every test here is
  # about the path where it does not.
  unset CLAUDE_PROJECT_ENCODED
}

# Stand up a git repo at $1. Sets REPO and MEM_DIR, where MEM_DIR is where the
# store MUST land for the hook to read it.
#
# The expected encoding is stated here rather than taken from the lib under
# test: a test that derives it the same way production does agrees with
# production by construction and cannot catch a wrong encoder.
# setup_test_env unsets CLAUDE_CONFIG_DIR, so the template's config-dir half
# falls back to $HOME/.claude.
_repo_at() {
  REPO="$1"
  mkdir -p "${REPO}/.claude" "${REPO}/scripts"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" remote add origin git@github.com:org/curator-encoding-test.git

  # Generous wall-clock budget only. memory_store_path is deliberately NOT
  # overridden — the shipped template is what these tests exercise.
  jq -n '{ curator: { cheap_checks: { wall_clock_budget_ms: 600000 } } }' \
    > "${REPO}/.claude/settings.json"

  local abs
  abs=$(cd "$REPO" && pwd -P)
  MEM_DIR="${TEST_HOME}/.claude/projects/$(printf '%s' "$abs" | sed -E 's#[/.]#-#g')/memory"
}

_input() {
  jq -cn --arg cwd "$REPO" --arg sid "sess-curator-encoding" \
    '{cwd: $cwd, source: "startup", session_id: $sid}'
}

# A memory file with no MEMORY.md reference is a deterministic orphan finding,
# so its presence proves the hook actually read the store.
_seed_orphan() {
  mkdir -p "$MEM_DIR"
  printf -- '---\nname: %s\ndescription: test\ntype: user\n---\n\n%s\n' \
    "user_orphan.md" "Some orphaned context." > "${MEM_DIR}/user_orphan.md"
}

@test "the hook audits the store when CLAUDE_PROJECT_ENCODED is unset" {
  _repo_at "${BATS_TEST_TMPDIR}/plain-repo"
  _seed_orphan

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  # Proof the store was found and read, not skipped.
  grep '"event_type":"curator.finding.orphaned_memory"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.memory_file == "user_orphan.md"' >/dev/null
}

@test "a project path containing a dot resolves to the dot-encoded store" {
  # github.com-shaped layout: the case that makes dots load-bearing.
  _repo_at "${BATS_TEST_TMPDIR}/src/github.com/org/dotted"
  _seed_orphan

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"curator.finding.orphaned_memory"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.memory_file == "user_orphan.md"' >/dev/null || return 1

  # An encoded project dir can never contain a dot.
  local dotted
  dotted=$(find "${TEST_HOME}/.claude/projects" -mindepth 1 -maxdepth 1 \
    -type d -name '*.*' 2>/dev/null)
  [ -z "$dotted" ]
}

@test "a resolved store that does not exist still reports ok" {
  # Resolution succeeds; there is simply no store yet. That is a real
  # "nothing to audit" and must stay outcome: ok.
  _repo_at "${BATS_TEST_TMPDIR}/no-store-repo"
  [ ! -d "$MEM_DIR" ] || return 1

  run bash -c "printf '%s' '$(_input)' | '$HOOK'"
  [ "$status" -eq 0 ] || return 1

  grep '"event_type":"curator.scan.complete"' "$ONLOOKER_EVENTS_LOG" \
    | jq -e '.payload.outcome == "ok" and .payload.findings_new == 0' >/dev/null
}

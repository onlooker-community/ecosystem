#!/usr/bin/env bats

# Exercises counsel_generate_brief's staleness gate and the force bypass the
# on-demand /counsel skill relies on. The claude CLI is stubbed so synthesis is
# deterministic and offline.

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/counsel"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-config.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-events.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-project-key.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-ulid.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-reader.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-synthesize.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/counsel-brief.sh"

  # A git work tree so counsel_project_key resolves to a stable root key.
  WORK="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$WORK"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email test@example.com
  git -C "$WORK" config user.name test

  counsel_config_load "$WORK"

  # Stub the claude CLI: ignore stdin/args, emit a valid synthesis object whose
  # summary carries a marker we can assert on in the written brief.
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"summary":"SYNTH_MARKER weekly review","patterns":["pattern one"],"recommendations":[{"title":"do x","rationale":"because y","priority":"high"}],"wins":["win one"],"watch":["watch one"]}
JSON
STUB
  chmod +x "${STUB_BIN}/claude"
  export PATH="${STUB_BIN}:${PATH}"

  # Event log with comfortably more than min_events records in-window.
  export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
  mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="2099-01-01T00:00:00Z"
  : > "$ONLOOKER_EVENTS_LOG"
  local i
  for ((i = 0; i < 12; i++)); do
    printf '%s\n' \
      "{\"event_type\":\"tribunal.gate.blocked\",\"timestamp\":\"${ts}\",\"session_id\":\"s${i}\",\"payload\":{}}" \
      >> "$ONLOOKER_EVENTS_LOG"
  done

  PROJECT_KEY=$(counsel_project_key "$WORK")
  BRIEFS_DIR=$(counsel_project_dir "$PROJECT_KEY")
  mkdir -p "$BRIEFS_DIR"
}

# ---------------------------------------------------------------------------
# Staleness gate (default, non-force path used by the SessionStart hook)
# ---------------------------------------------------------------------------

# counsel_generate_brief prints the brief path on stdout and diagnostics on
# stderr; capture stdout only so $out is exactly the path.
gen() {
  GEN_STATUS=0
  GEN_OUT=$(counsel_generate_brief "$@" 2>/dev/null) || GEN_STATUS=$?
}

@test "generate_brief writes a brief when none exists yet" {
  gen "sess-1" "$WORK"
  [ "$GEN_STATUS" -eq 0 ]
  [ -f "$GEN_OUT" ]
  grep -q "SYNTH_MARKER" "$GEN_OUT"
}

@test "generate_brief skips (rc=2) when the latest brief is still fresh" {
  # A freshly written brief makes counsel_brief_is_stale return false.
  printf '# old brief\n' > "${BRIEFS_DIR}/2099-01.md"
  gen "sess-2" "$WORK"
  [ "$GEN_STATUS" -eq 2 ]
}

# Bullet lists and the rule in the rendered brief must not be mangled by
# printf treating a leading dash as an option.
@test "rendered brief contains intact bullets and horizontal rule" {
  gen "sess-bullets" "$WORK"
  [ "$GEN_STATUS" -eq 0 ]
  grep -q '^- pattern one$' "$GEN_OUT"
  grep -q '^- win one$' "$GEN_OUT"
  grep -q '^---$' "$GEN_OUT"
}

# ---------------------------------------------------------------------------
# Force bypass (on-demand /counsel skill path)
# ---------------------------------------------------------------------------

@test "force bypasses the staleness gate and regenerates a fresh brief" {
  printf '# stale-looking but fresh-on-disk brief\n' > "${BRIEFS_DIR}/2099-01.md"

  gen "sess-3" "$WORK" force
  [ "$GEN_STATUS" -eq 0 ]
  [ -f "$GEN_OUT" ]
  grep -q "SYNTH_MARKER" "$GEN_OUT"
}

@test "force accepts the literal \"1\" as well" {
  printf '# fresh\n' > "${BRIEFS_DIR}/2099-01.md"
  gen "sess-4" "$WORK" 1
  [ "$GEN_STATUS" -eq 0 ]
  grep -q "SYNTH_MARKER" "$GEN_OUT"
}

@test "force still respects the min_events floor" {
  # Only a couple of events — below the default min_events of 10.
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || ts="2099-01-01T00:00:00Z"
  printf '%s\n' \
    "{\"event_type\":\"tribunal.gate.blocked\",\"timestamp\":\"${ts}\",\"session_id\":\"s1\",\"payload\":{}}" \
    "{\"event_type\":\"echo.regression.detected\",\"timestamp\":\"${ts}\",\"session_id\":\"s2\",\"payload\":{}}" \
    > "$ONLOOKER_EVENTS_LOG"

  gen "sess-5" "$WORK" force
  [ "$GEN_STATUS" -eq 2 ]
}

# Regression: counsel.brief.generated must validate against the schema and land
# in the event log. The period bounds are emitted as RFC 3339 date-time strings.
@test "generated brief emits a schema-valid counsel.brief.generated event" {
  gen "sess-evt" "$WORK"
  [ "$GEN_STATUS" -eq 0 ]
  run grep -c '"event_type":"counsel.brief.generated"' "$ONLOOKER_EVENTS_LOG"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
  # period_start must be a full date-time, not a bare calendar date.
  run grep -o '"period_start":"[^"]*"' "$ONLOOKER_EVENTS_LOG"
  [[ "$output" == *"T"*"Z"* ]]
}

# If date cannot produce timestamps the bounds are empty; rather than emit an
# event that fails schema validation, the emit is skipped and the brief is
# still written.
@test "emit is skipped (never invalid) when date cannot produce bounds" {
  local datestub="${BATS_TEST_TMPDIR}/datebin"
  mkdir -p "$datestub"
  printf '#!/usr/bin/env bash\nexit 1\n' > "${datestub}/date"
  chmod +x "${datestub}/date"
  PATH="${datestub}:${PATH}"

  gen "sess-nodate" "$WORK" force
  [ "$GEN_STATUS" -eq 0 ]
  [ -f "$GEN_OUT" ]
  grep -q "SYNTH_MARKER" "$GEN_OUT"
  # No counsel.brief.generated event should have been appended.
  run grep -c '"event_type":"counsel.brief.generated"' "$ONLOOKER_EVENTS_LOG"
  [ "$output" -eq 0 ]
}

# ---------------------------------------------------------------------------
# ONL-132 / ecosystem-ac8r8d.3. synthesis_interval_days and capture.min_events
# used the [[ -z || == "null" ]] idiom, then reached arithmetic:
#   interval_days -> [[ "$age_days"     -ge "$interval_days" ]]  (counsel-brief.sh:104)
#   min_events    -> [[ "$event_count"  -lt "$min_events"    ]]  (counsel-brief.sh:229)
# [[ -ge ]] / [[ -lt ]] evaluate their operands arithmetically and die on a bare
# word under set -u, exactly as (( )) does.
#
# interval_days is the staleness gate this whole file exercises, so a dead read
# there means counsel either never regenerates a brief or regenerates on every
# single SessionStart -- and at status 0 either way.
#
# Fixtures use "unlimited" rather than a digit-leading value, which would hit
# the milder surviving mode and pass against unfixed code.
# ---------------------------------------------------------------------------

@test "a non-numeric synthesis_interval_days falls back to the shipped default" {
  mkdir -p "${WORK}/.claude"
  printf '%s\n' '{"counsel":{"synthesis_interval_days":"unlimited"}}' > "${WORK}/.claude/settings.json"
  counsel_config_load "$WORK"
  [ "$(counsel_config_int '.counsel.synthesis_interval_days' 7)" = "7" ]
}

@test "a non-numeric capture.min_events falls back to the shipped default" {
  mkdir -p "${WORK}/.claude"
  printf '%s\n' '{"counsel":{"capture":{"min_events":"unlimited"}}}' > "${WORK}/.claude/settings.json"
  counsel_config_load "$WORK"
  [ "$(counsel_config_int '.counsel.capture.min_events' 10)" = "10" ]
}

@test "valid counsel int overrides still win" {
  mkdir -p "${WORK}/.claude"
  printf '%s\n' '{"counsel":{"synthesis_interval_days":14,"capture":{"min_events":25}}}' > "${WORK}/.claude/settings.json"
  counsel_config_load "$WORK"
  [ "$(counsel_config_int '.counsel.synthesis_interval_days' 7)" = "14" ] || return 1
  [ "$(counsel_config_int '.counsel.capture.min_events' 10)" = "25" ]
}

# SCOPE of the three tests above, stated plainly so they are not mistaken for
# coverage of the abort. They call counsel_config_int directly, so against
# unmigrated code they fail only because the function does not exist -- a
# tautology. What they genuinely guard is the config-var name: counsel populates
# `_counsel_CONFIG` (lowercase), while cartographer and governor use the
# uppercase spelling, and a wrapper pointed at the wrong one reads an unset
# variable, silently returns the default for every value, and ignores config
# entirely. Verified by mutation on the sibling plugin: renaming the var is
# caught by the "valid override still wins" assertion and by NOTHING else --
# the "falls back" assertions pass under it, because reading an unset variable
# also yields the default.
#
# WHY THERE IS NO LIB-LEVEL ABORT TEST HERE. counsel-brief.sh carries no `set`
# line of its own -- it is a sourced lib, and its callers
# (counsel-session-start.sh, counsel-refresh.sh) are what run set -uo pipefail.
# A bats file that sources the lib therefore runs it WITHOUT set -u, so the
# unbound-variable abort cannot happen and any such test passes against
# unguarded code. Measured: two consumer tests written that way both passed
# before the fix. The mechanism is real -- `[[ "$x" -lt "$word" ]]` does abort
# under set -u, confirmed in isolation -- but only in a process that set it.
#
# So the one abort test below drives counsel-refresh.sh, a real script with
# set -uo pipefail at :21. It covers min_events only: refresh calls
# counsel_generate_brief with `force`, which skips counsel_brief_is_stale, and
# the interval_days comparison lives inside that function -- so interval_days
# is read but never reaches arithmetic on this path. Its guard rests on the
# wiring test above plus config-get-int.bats.
@test "a non-numeric capture.min_events does not kill the refresh run" {
  mkdir -p "${WORK}/.claude"
  printf '%s\n' '{"counsel":{"capture":{"min_events":"unlimited"}}}' > "${WORK}/.claude/settings.json"

  # "unlimited", not "10events": digit-leading would make [[ -lt ]] merely
  # return non-zero, the script would survive, and the test would pass against
  # unguarded code. config-get-int.bats covers that milder mode.
  run bash -c "'${PLUGIN_ROOT}/scripts/counsel-refresh.sh' sess-refresh-badmin '$WORK' '$PROJECT_KEY'"
  [ "$status" -eq 0 ] || return 1

  # The setup seeds 12 events, clearing the shipped floor of 10, so a working
  # fallback lets synthesis proceed and write a brief. Unguarded, the script
  # dies at the comparison and the directory stays empty.
  local written
  written=$(find "$BRIEFS_DIR" -name '*.md' -type f | wc -l | tr -d ' ')
  [ "$written" -ge 1 ]
}

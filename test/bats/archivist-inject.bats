#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  # Stand up a fake project repo so project-key resolution succeeds.
  PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$PROJECT_REPO"
  git -C "$PROJECT_REPO" init -q
  git -C "$PROJECT_REPO" config user.email t@example.com
  git -C "$PROJECT_REPO" config user.name "Test"
  git -C "$PROJECT_REPO" remote add origin git@github.com:org/archivist-inject-test.git

  # Compute the project key the hook will use.
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
  PROJECT_KEY=$(onlooker_project_key "$PROJECT_REPO")
  [ -n "$PROJECT_KEY" ]

  # Seed an artifact on disk for this project.
  local kind_dir="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions"
  mkdir -p "$kind_dir"
  printf '%s\n' '{
    "id": "01TESTTESTTESTTESTTESTTEST",
    "kind": "decision",
    "summary": "use git remote SHA256 as project key",
    "detail": "remote URL is stable across machines; falls back to repo path",
    "files": [],
    "created_at": "2026-05-22T10:00:00Z",
    "updated_at": "2026-05-22T10:00:00Z"
  }' > "${kind_dir}/01TESTTESTTESTTESTTESTTEST.json"

}

@test "inject hook emits seeded artifact" {
  local input
  input=$(jq -n --arg cwd "$PROJECT_REPO" '{cwd: $cwd, source: "startup", session_id: "s"}')
  run bash -c "printf '%s' '$input' | '${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh'"
  [ "$status" -eq 0 ]

  echo "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"use git remote SHA256 as project key"* ]] || return 1
  [[ "$ctx" == *"Archivist injected 1"* ]]
}

@test "inject hook skips when there is no git context" {
  local non_git="${BATS_TEST_TMPDIR}/no-git"
  mkdir -p "$non_git"
  local input
  input=$(jq -n --arg cwd "$non_git" '{cwd: $cwd, source: "startup", session_id: "s"}')
  run bash -c "printf '%s' '$input' | '${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh'"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

# ONL-132. "2400 chars" is the kind of thing a person writes for a character
# budget. The old idiom guarded empty and the literal "null" only, so the value
# reached `(( RUNNING_CHARS + LINE_LEN > MAX_CHARS ))` at archivist-inject.sh:142,
# bash read `chars` as a variable name, set -u stopped the shell, and -- with no
# -e -- the status left behind was 0. The hook exits 0 either way, so the
# assertion has to be on the injected context, not on status.
@test "a non-numeric injection budget still injects the artifact" {
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' '{"archivist":{"injection":{"max_chars":"2400 chars","max_items":"8 items"}}}' \
    > "${PROJECT_REPO}/.claude/settings.json"

  local input
  input=$(jq -n --arg cwd "$PROJECT_REPO" '{cwd: $cwd, source: "startup", session_id: "s"}')
  run bash -c "printf '%s' '$input' | '${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh'"
  [ "$status" -eq 0 ] || return 1

  local ctx
  ctx=$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"use git remote SHA256 as project key"* ]] || return 1
  [[ "$ctx" == *"Archivist injected 1"* ]]
}

_run_inject() {
  local input
  input=$(jq -n --arg cwd "$PROJECT_REPO" '{cwd: $cwd, source: "startup", session_id: "s"}')
  printf '%s' "$input" | "${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh"
}

_ctx() { _run_inject | jq -r '.hookSpecificOutput.additionalContext'; }

# Writes an artifact: <kind> <id> <updated_at> <json fields to merge>.
_artifact() {
  local dir="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/$1"
  mkdir -p "$dir"
  jq -n --arg id "$2" --arg at "$3" --argjson extra "$4" \
    '{id: $id, created_at: $at, updated_at: $at} + $extra' >"${dir}/$2.json"
}

_settings() {
  mkdir -p "${PROJECT_REPO}/.claude"
  printf '%s\n' "$1" >"${PROJECT_REPO}/.claude/settings.json"
}

# Counts jq starts while still running the real jq.
_count_inject_jq_starts() {
  local shim="${BATS_TEST_TMPDIR}/shim" real
  real=$(command -v jq)
  mkdir -p "$shim"
  cat >"${shim}/jq" <<SHIM
#!/usr/bin/env bash
printf 'x\n' >>"${BATS_TEST_TMPDIR}/jq-starts"
exec "$real" "\$@"
SHIM
  chmod +x "${shim}/jq"
  rm -f "${BATS_TEST_TMPDIR}/jq-starts"
  PATH="${shim}:${PATH}" _run_inject >"${BATS_TEST_TMPDIR}/injected"
  wc -l <"${BATS_TEST_TMPDIR}/jq-starts" | tr -d ' '
}

# The render loop re-parsed the whole artifact list several times per item, and
# the list holds every artifact the project has: ~780ms for 8 items at 1,221
# artifacts (ONL-114).
@test "injecting starts the same number of jq processes however many artifacts exist" {
  local i small large
  for i in 1 2; do _artifact decisions "a$i" "2026-05-0${i}T00:00:00Z" '{"summary":"s"}'; done
  small=$(_count_inject_jq_starts)
  for i in $(seq 3 30); do _artifact decisions "a$i" "2026-05-01T00:00:00Z" '{"summary":"s"}'; done
  large=$(_count_inject_jq_starts)

  [ "$small" -eq "$large" ]
  jq -r .hookSpecificOutput.additionalContext "${BATS_TEST_TMPDIR}/injected" | grep -q 'injected 8/31 items'
}

@test "the rendered context keeps its exact shape" {
  rm -f "${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions/"*.json
  _artifact decisions d1 "2026-06-03T00:00:00Z" '{"summary":"newest decision","detail":"why","files":["a.sh","b.sh"]}'
  _artifact dead_ends e1 "2026-06-02T00:00:00Z" '{"summary":"tried it","detail":"null"}'
  _artifact open_questions q1 "2026-06-01T00:00:00Z" '{"summary":"still open"}'
  _artifact decisions d0 "2026-05-01T00:00:00Z" '{"summary":"old but pinned"}'
  _artifact decisions blank "2026-06-04T00:00:00Z" '{"summary":""}'
  printf '{"ids":["d0"]}\n' >"${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/pinned.json"

  run _ctx
  [ "$status" -eq 0 ]
  local expected
  expected="Archivist — carried over from prior sessions in this repo (kind | summary):
- [pinned decision] old but pinned
- [decision] newest decision
  why
  files: a.sh, b.sh
- [dead-end] tried it
- [open-question] still open

(Archivist injected 4/5 items for project key ${PROJECT_KEY}. Source: startup.)"
  [ "$output" = "$expected" ]
}

@test "max_items caps what is injected, and empty summaries do not count toward it" {
  rm -f "${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions/"*.json
  _artifact decisions blank "2026-06-04T00:00:00Z" '{"summary":""}'
  _artifact decisions d3 "2026-06-03T00:00:00Z" '{"summary":"three"}'
  _artifact decisions d2 "2026-06-02T00:00:00Z" '{"summary":"two"}'
  _artifact decisions d1 "2026-06-01T00:00:00Z" '{"summary":"one"}'
  _settings '{"archivist":{"injection":{"max_items":2}}}'

  run _ctx
  [[ "$output" == *"- [decision] three"$'\n'"- [decision] two"$'\n\n'"(Archivist injected 2/4 items"* ]]
}

@test "the first item over max_chars ends the list, even when a later one would fit" {
  rm -f "${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions/"*.json
  _artifact decisions d3 "2026-06-03T00:00:00Z" '{"summary":"fits"}'
  _artifact decisions d2 "2026-06-02T00:00:00Z" "$(jq -n '{summary: ("x" * 200)}')"
  _artifact decisions d1 "2026-06-01T00:00:00Z" '{"summary":"small"}'
  # Header (75 chars) + "- [decision] fits" (17 + 1 newline) = 93.
  _settings '{"archivist":{"injection":{"max_chars":120}}}'

  run _ctx
  [[ "$output" == *"- [decision] fits"$'\n\n'"(Archivist injected 1/3 items"* ]] || return 1
  [[ "$output" != *"small"* ]]
}

@test "disabled kinds are left out but still counted in the total" {
  _artifact dead_ends e1 "2026-06-02T00:00:00Z" '{"summary":"a dead end"}'
  _artifact open_questions q1 "2026-06-01T00:00:00Z" '{"summary":"a question"}'
  _settings '{"archivist":{"injection":{"include_dead_ends":false,"include_open_questions":false}}}'

  run _ctx
  [[ "$output" != *"a dead end"* && "$output" != *"a question"* ]] || return 1
  [[ "$output" == *"injected 1/3 items"* ]]
}

@test "a corrupt artifact costs only itself" {
  _artifact decisions d2 "2026-06-02T00:00:00Z" '{"summary":"still here"}'
  printf '{"id":"broken","summary":' >"${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions/broken.json"

  run _ctx
  [[ "$output" == *"still here"* && "$output" == *"use git remote SHA256"* ]]
}

@test "nothing to inject emits an empty context" {
  rm -f "${ONLOOKER_DIR}/archivist/${PROJECT_KEY}/decisions/"*.json
  _artifact decisions blank "2026-06-04T00:00:00Z" '{"summary":""}'

  run _run_inject
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
}

# --- The injection cache (ONL-260) -------------------------------------------
#
# Rendering re-reads every artifact the project has to show at most eight of
# them: ~60ms of jq at 1,345 artifacts, and 2.4x that under SessionStart
# contention. The cache is valid while it is strictly newer than every kind
# directory and pinned.json. Writers create a file per artifact, so a write
# moves its directory's mtime. A change in the same second as the cache is a
# miss, which is why these tests backdate the corpus before building one.

_project_dir() { printf '%s' "${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"; }

_backdate_corpus() {
  local p
  for p in decisions dead_ends open_questions pinned.json; do
    [[ -e "$(_project_dir)/$p" ]] && touch -t 202001010000 "$(_project_dir)/$p"
  done
  return 0
}

# A later second than the cache, whatever second it was built in. Not a
# backdated cache: that would also be older than the hook script, and miss on
# that alone.
_future() { touch -t "$(($(date +%Y) + 1))01010000" "$1"; }

_run_inject_as() {
  jq -n --arg cwd "$PROJECT_REPO" --arg src "$1" '{cwd: $cwd, source: $src, session_id: "s"}' \
    | "${PLUGIN_ROOT}/scripts/hooks/archivist-inject.sh"
}

# Logs every jq argument list, still running the real jq.
_log_jq_args() {
  local shim="${BATS_TEST_TMPDIR}/argshim" real
  real=$(command -v jq)
  mkdir -p "$shim"
  cat >"${shim}/jq" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${BATS_TEST_TMPDIR}/jq-args"
exec "$real" "\$@"
SHIM
  chmod +x "${shim}/jq"
  : >"${BATS_TEST_TMPDIR}/jq-args"
  printf '%s' "$shim"
}

@test "an unchanged corpus is answered without reading an artifact" {
  _artifact dead_ends e1 "2026-06-02T00:00:00Z" '{"summary":"a dead end","files":["x.sh"]}'
  _backdate_corpus
  local first second shim
  first=$(_run_inject_as startup)
  shim=$(_log_jq_args)
  second=$(PATH="${shim}:${PATH}" _run_inject_as startup)

  [[ "$first" == *"a dead end"* ]] || return 1
  [ "$second" = "$first" ] || return 1
  ! grep -q '/decisions/\|/dead_ends/' "${BATS_TEST_TMPDIR}/jq-args"
}

@test "a cached answer names the source of the session it answers" {
  _backdate_corpus
  local first second shim
  first=$(_run_inject_as startup)
  shim=$(_log_jq_args)
  second=$(PATH="${shim}:${PATH}" _run_inject_as compact)

  ! grep -q '/decisions/' "${BATS_TEST_TMPDIR}/jq-args" || return 1
  [ "$second" = "${first/Source: startup./Source: compact.}" ]
}

@test "an artifact written after the cache is injected" {
  _backdate_corpus
  _run_inject_as startup >/dev/null
  _artifact decisions later "2026-07-01T00:00:00Z" '{"summary":"written later"}'
  _future "$(_project_dir)/decisions"

  run _ctx
  [[ "$output" == *"written later"* ]]
}

@test "an artifact written in the same second as the cache is injected" {
  _backdate_corpus
  _run_inject_as startup >/dev/null
  _artifact decisions later "2026-07-01T00:00:00Z" '{"summary":"written later"}'

  run _ctx
  [[ "$output" == *"written later"* ]]
}

@test "a new kind directory is injected" {
  _backdate_corpus
  _run_inject_as startup >/dev/null
  _artifact open_questions q1 "2026-07-01T00:00:00Z" '{"summary":"a new question"}'
  touch -t 202001010000 "$(_project_dir)/open_questions"

  run _ctx
  [[ "$output" == *"a new question"* ]]
}

@test "a pin made after the cache is injected" {
  _artifact decisions old "2020-01-01T00:00:00Z" '{"summary":"old one"}'
  # Present before the cache, so the pin changes no path's existence.
  printf '{"ids":[]}\n' >"$(_project_dir)/pinned.json"
  _backdate_corpus
  _run_inject_as startup >/dev/null
  printf '{"ids":["old"]}\n' >"$(_project_dir)/pinned.json"
  _future "$(_project_dir)/pinned.json"

  run _ctx
  [[ "$output" == *"- [pinned decision] old one"* ]]
}

@test "a cache built under other budgets is not used" {
  _artifact decisions d2 "2026-06-02T00:00:00Z" '{"summary":"second"}'
  _backdate_corpus
  _run_inject_as startup >/dev/null
  _settings '{"archivist":{"injection":{"max_items":1}}}'

  run _ctx
  [[ "$output" == *"injected 1/2 items"* ]]
}

# The cache is stamped with the time its read began, not the time it was
# written. Otherwise an artifact written mid-read would land in neither: not in
# the rendered list, and not newer than the cache that rendered it.
@test "an artifact written while the corpus is read is injected next time" {
  _backdate_corpus
  local shim="${BATS_TEST_TMPDIR}/racer" real
  real=$(command -v jq)
  mkdir -p "$shim"
  cat >"${shim}/jq" <<SHIM
#!/usr/bin/env bash
if [[ "\$*" == *"/decisions/"* && ! -e "${BATS_TEST_TMPDIR}/raced" ]]; then
  : >"${BATS_TEST_TMPDIR}/raced"
  sleep 1.1
  printf '%s\n' '{"id":"racer","summary":"written mid-read","created_at":"2026-08-01T00:00:00Z","updated_at":"2026-08-01T00:00:00Z"}' \
    >"$(_project_dir)/decisions/racer.json"
  sleep 1.1
fi
exec "$real" "\$@"
SHIM
  chmod +x "${shim}/jq"
  PATH="${shim}:${PATH}" _run_inject_as startup >/dev/null
  [ -e "${BATS_TEST_TMPDIR}/raced" ] || return 1

  run _ctx
  [[ "$output" == *"written mid-read"* ]]
}

@test "a corrupt cache is read past" {
  _backdate_corpus
  local first
  first=$(_run_inject_as startup)
  printf 'garbage\n' >"$(_project_dir)/.inject-cache"

  run _run_inject_as startup
  [ "$output" = "$first" ]
}

@test "a cached empty answer stays an empty context" {
  rm -f "$(_project_dir)/decisions/"*.json
  _artifact decisions blank "2026-06-04T00:00:00Z" '{"summary":""}'
  _backdate_corpus
  _run_inject_as startup >/dev/null

  run _run_inject_as startup
  [ "$output" = '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":""}}' ]
}

@test "a store the hook cannot write to still injects" {
  _backdate_corpus
  chmod 555 "$(_project_dir)"
  run _ctx
  chmod 755 "$(_project_dir)"
  [[ "$output" == *"use git remote SHA256 as project key"* ]] || return 1
  [ ! -e "$(_project_dir)/.inject-cache" ]
}

# A changed render must not answer with a body the old one cached. Releases
# install to their own directory, which the key carries; an edit in place moves
# the render lib's mtime. On a copy, so the real lib's mtime is left alone for
# the tests running beside this one.
@test "an edited render does not answer from a cache the old one wrote" {
  local copy="${BATS_TEST_TMPDIR}/archivist-copy"
  cp -R "$PLUGIN_ROOT" "$copy"
  _backdate_corpus
  local input
  input=$(jq -n --arg cwd "$PROJECT_REPO" '{cwd: $cwd, source: "startup", session_id: "s"}')
  printf '%s' "$input" | "${copy}/scripts/hooks/archivist-inject.sh" >/dev/null
  sed -i.bak 's/Archivist — carried over/Archivist (edited) — carried over/' \
    "${copy}/scripts/lib/archivist-inject-cache.sh"
  _future "${copy}/scripts/lib/archivist-inject-cache.sh"

  run bash -c "printf '%s' '$input' | '${copy}/scripts/hooks/archivist-inject.sh'"
  [[ "$output" == *"Archivist (edited)"* ]]
}

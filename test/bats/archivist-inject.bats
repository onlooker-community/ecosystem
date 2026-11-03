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
  [[ "$output" == *"- [decision] fits"$'\n\n'"(Archivist injected 1/3 items"* ]]
  [[ "$output" != *"small"* ]]
}

@test "disabled kinds are left out but still counted in the total" {
  _artifact dead_ends e1 "2026-06-02T00:00:00Z" '{"summary":"a dead end"}'
  _artifact open_questions q1 "2026-06-01T00:00:00Z" '{"summary":"a question"}'
  _settings '{"archivist":{"injection":{"include_dead_ends":false,"include_open_questions":false}}}'

  run _ctx
  [[ "$output" != *"a dead end"* && "$output" != *"a question"* ]]
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

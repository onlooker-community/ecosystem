#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/cartographer-omission.sh"

  FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${FIXTURE_REPO}/plugins/alpha" \
           "${FIXTURE_REPO}/plugins/beta" \
           "${FIXTURE_REPO}/skills/solo"
  DOC="${FIXTURE_REPO}/CLAUDE.md"
  printf '# Doc\nThe alpha plugin does things.\n' > "$DOC"
  CORPUS=$(jq -n --arg f "$DOC" '[$f]')
}

@test "flags an entity whose name appears nowhere in the corpus" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [[ "$(printf '%s' "$out" | jq -r 'length')" == "1" ]] || return 1
  [[ "$(printf '%s' "$out" | jq -r '.[0].excerpt_a')" == "beta" ]] || return 1
  [ "$(printf '%s' "$out" | jq -r '.[0].type')" = "undocumented_entity" ]
}

@test "does not flag an entity the corpus mentions" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [ "$(printf '%s' "$out" | jq -r '[.[] | select(.excerpt_a == "alpha")] | length')" = "0" ]
}

@test "finding carries the entity as file_a and a null file_b" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [[ "$(printf '%s' "$out" | jq -r '.[0].file_a')" == "${FIXTURE_REPO}/plugins/beta" ]] || return 1
  [[ "$(printf '%s' "$out" | jq -r '.[0].file_b')" == "null" ]] || return 1
  [ "$(printf '%s' "$out" | jq -r '.[0].severity')" = "warning" ]
}

@test "word boundary: a longer word containing the name does not count as a mention" {
  printf '# Doc\nWe do a lot of counseling here.\n' > "$DOC"
  mkdir -p "${FIXTURE_REPO}/plugins/counsel"
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [ "$(printf '%s' "$out" | jq -r '[.[] | select(.excerpt_a == "counsel")] | length')" = "1" ]
}

@test "word boundary: a hyphenated name is not matched inside a longer hyphenated token" {
  printf '# Doc\nSee my-list-prompt-rules-thing for details.\n' > "$DOC"
  mkdir -p "${FIXTURE_REPO}/skills/list-prompt-rules"
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["skills/*/"]' '[]' 20)
  [ "$(printf '%s' "$out" | jq -r '[.[] | select(.excerpt_a == "list-prompt-rules")] | length')" = "1" ]
}

@test "word boundary: a name bounded by slashes counts as a mention" {
  printf '# Doc\nSee plugins/beta/ for details.\n' > "$DOC"
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [ "$(printf '%s' "$out" | jq -r '[.[] | select(.excerpt_a == "beta")] | length')" = "0" ]
}

@test "exclude filters a matched path by substring" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/","skills/*/"]' '["skills/"]' 20)
  [[ "$(printf '%s' "$out" | jq -r 'length')" == "1" ]] || return 1
  [ "$(printf '%s' "$out" | jq -r '.[0].excerpt_a')" = "beta" ]
}

@test "max_findings caps the result and reports the drop count on stderr" {
  local out err
  err="${BATS_TEST_TMPDIR}/err.txt"
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/","skills/*/"]' '[]' 1 2>"$err")
  [[ "$(printf '%s' "$out" | jq -r 'length')" == "1" ]] || return 1
  grep -q "1 candidate" "$err"
}

@test "a glob matching nothing yields an empty array" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["nonexistent/*/"]' '[]' 20)
  [ "$out" = "[]" ]
}

@test "an empty corpus yields an empty array rather than flagging everything" {
  local out
  out=$(cartographer_analyze_undocumented_entity \
    '[]' "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  [ "$out" = "[]" ]
}

@test "the same entity produces an identical finding hash across two runs" {
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/cartographer-analyze.sh"
  local a b h1 h2
  a=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  b=$(cartographer_analyze_undocumented_entity \
    "$CORPUS" "$FIXTURE_REPO" '["plugins/*/"]' '[]' 20)
  h1=$(cartographer_finding_hash "undocumented_entity" \
    "$(printf '%s' "$a" | jq -r '.[0].file_a')" \
    "$(printf '%s' "$a" | jq -r '.[0].excerpt_a')" "" "")
  h2=$(cartographer_finding_hash "undocumented_entity" \
    "$(printf '%s' "$b" | jq -r '.[0].file_a')" \
    "$(printf '%s' "$b" | jq -r '.[0].excerpt_a')" "" "")
  [[ -n "$h1" ]] || return 1
  [ "$h1" = "$h2" ]
}

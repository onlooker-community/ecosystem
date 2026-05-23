#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"
  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/archivist-ulid.sh"

  REPO="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$REPO/src"
  : > "$REPO/src/known.ts"
  : > "$REPO/README.md"
}

@test "validate accepts an existing repo-relative path" {
  run archivist_validate_repo_path "$REPO" "src/known.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "src/known.ts" ]
}

@test "validate accepts an absolute path inside the repo" {
  run archivist_validate_repo_path "$REPO" "${REPO}/src/known.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "src/known.ts" ]
}

@test "validate rejects a path outside the repo" {
  local outside="${BATS_TEST_TMPDIR}/outside.ts"
  : > "$outside"
  run archivist_validate_repo_path "$REPO" "$outside"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate rejects a ../ escape" {
  run archivist_validate_repo_path "$REPO" "../escaped.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate rejects a path that does not exist" {
  run archivist_validate_repo_path "$REPO" "src/missing.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "validate_paths_array strips invalid entries" {
  local input='["src/known.ts","../escape.ts","src/missing.ts","README.md"]'
  local cleaned compact
  cleaned=$(archivist_validate_paths_array "$REPO" "$input")
  compact=$(printf '%s' "$cleaned" | jq -c .)
  [ "$compact" = '["src/known.ts","README.md"]' ]
}

@test "storage_init creates kind directories" {
  local key="abc123def456"
  archivist_storage_init "$key"
  [ -d "${ONLOOKER_DIR}/archivist/${key}/decisions" ]
  [ -d "${ONLOOKER_DIR}/archivist/${key}/dead_ends" ]
  [ -d "${ONLOOKER_DIR}/archivist/${key}/open_questions" ]
}

@test "write_artifact creates a ULID-keyed file" {
  local key="abc123def456"
  local id
  id=$(archivist_ulid)
  local json='{"id":"'"$id"'","kind":"decision","summary":"hello"}'
  run archivist_storage_write_artifact "$key" "decisions" "$id" "$json"
  [ "$status" -eq 0 ]
  [ -f "${ONLOOKER_DIR}/archivist/${key}/decisions/${id}.json" ]
}

@test "write_artifact rejects unknown kind" {
  local key="abc123def456"
  run archivist_storage_write_artifact "$key" "bogus_kind" "01J" '{}'
  [ "$status" -ne 0 ]
}

@test "load_ranked sorts pinned items first" {
  local key="abc123def456"
  archivist_storage_init "$key"

  # Write two decisions; pin the older one.
  local older_id="01AAAAAAAAAAAAAAAAAAAAAAAA"
  local newer_id="01ZZZZZZZZZZZZZZZZZZZZZZZZ"
  printf '{"id":"%s","summary":"older","created_at":"2026-05-01T00:00:00Z","updated_at":"2026-05-01T00:00:00Z"}\n' "$older_id" \
    > "${ONLOOKER_DIR}/archivist/${key}/decisions/${older_id}.json"
  printf '{"id":"%s","summary":"newer","created_at":"2026-05-22T00:00:00Z","updated_at":"2026-05-22T00:00:00Z"}\n' "$newer_id" \
    > "${ONLOOKER_DIR}/archivist/${key}/decisions/${newer_id}.json"
  printf '{"ids":["%s"]}\n' "$older_id" > "${ONLOOKER_DIR}/archivist/${key}/pinned.json"

  local ranked
  ranked=$(archivist_storage_load_ranked "$key")
  local first_id
  first_id=$(printf '%s' "$ranked" | jq -r '.[0].id')
  [ "$first_id" = "$older_id" ]
}

@test "load_ranked sorts non-pinned by recency desc" {
  local key="abc123def456"
  archivist_storage_init "$key"
  local older_id="01AAAAAAAAAAAAAAAAAAAAAAAA"
  local newer_id="01ZZZZZZZZZZZZZZZZZZZZZZZZ"
  printf '{"id":"%s","summary":"older","created_at":"2026-05-01T00:00:00Z","updated_at":"2026-05-01T00:00:00Z"}\n' "$older_id" \
    > "${ONLOOKER_DIR}/archivist/${key}/decisions/${older_id}.json"
  printf '{"id":"%s","summary":"newer","created_at":"2026-05-22T00:00:00Z","updated_at":"2026-05-22T00:00:00Z"}\n' "$newer_id" \
    > "${ONLOOKER_DIR}/archivist/${key}/decisions/${newer_id}.json"

  local ranked
  ranked=$(archivist_storage_load_ranked "$key")
  local first_id
  first_id=$(printf '%s' "$ranked" | jq -r '.[0].id')
  [ "$first_id" = "$newer_id" ]
}

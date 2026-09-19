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

@test "storage_root prints the archivist dir under ONLOOKER_DIR" {
  run archivist_storage_root
  [ "$status" -eq 0 ]
  [ "$output" = "${ONLOOKER_DIR}/archivist" ]
}

@test "project_dir prints root joined with the key" {
  local key="abc123def456"
  run archivist_project_dir "$key"
  [ "$status" -eq 0 ]
  [ "$output" = "${ONLOOKER_DIR}/archivist/${key}" ]
}

@test "kind_dir prints the per-kind subdir under the project dir" {
  local key="abc123def456"
  run archivist_kind_dir "$key" "decisions"
  [ "$status" -eq 0 ]
  [ "$output" = "${ONLOOKER_DIR}/archivist/${key}/decisions" ]
}

@test "kind_dir honors an arbitrary kind name" {
  local key="abc123def456"
  run archivist_kind_dir "$key" "dead_ends"
  [ "$status" -eq 0 ]
  [ "$output" = "${ONLOOKER_DIR}/archivist/${key}/dead_ends" ]
}

@test "write_manifest creates manifest.json under the project dir" {
  local key="abc123def456"
  run archivist_storage_write_manifest "$key" "git@github.com:org/repo.git" "$REPO"
  [ "$status" -eq 0 ]
  [ -f "${ONLOOKER_DIR}/archivist/${key}/manifest.json" ]
}

@test "write_manifest records the project_key, remote_url, and repo_root" {
  local key="abc123def456"
  local remote="git@github.com:org/repo.git"
  archivist_storage_write_manifest "$key" "$remote" "$REPO"
  local manifest="${ONLOOKER_DIR}/archivist/${key}/manifest.json"

  [ "$(jq -r '.project_key' "$manifest")" = "$key" ]
  [ "$(jq -r '.remote_url' "$manifest")" = "$remote" ]
  [ "$(jq -r '.repo_root' "$manifest")" = "$REPO" ]
  [ "$(jq -r '.source' "$manifest")" = "local" ]
}

@test "write_manifest stamps an ISO-8601 last_compact_at timestamp" {
  local key="abc123def456"
  archivist_storage_write_manifest "$key" "remote" "$REPO"
  local manifest="${ONLOOKER_DIR}/archivist/${key}/manifest.json"

  local ts
  ts=$(jq -r '.last_compact_at' "$manifest")
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "write_manifest stores null for an empty remote_url" {
  local key="abc123def456"
  archivist_storage_write_manifest "$key" "" "$REPO"
  local manifest="${ONLOOKER_DIR}/archivist/${key}/manifest.json"

  [ "$(jq -r '.remote_url' "$manifest")" = "null" ]
  [ "$(jq '.remote_url == null' "$manifest")" = "true" ]
}

@test "write_manifest stores null for an empty repo_root" {
  local key="abc123def456"
  archivist_storage_write_manifest "$key" "remote" ""
  local manifest="${ONLOOKER_DIR}/archivist/${key}/manifest.json"

  [ "$(jq -r '.repo_root' "$manifest")" = "null" ]
  [ "$(jq '.repo_root == null' "$manifest")" = "true" ]
}

@test "write_manifest rejects an empty key" {
  run archivist_storage_write_manifest "" "remote" "$REPO"
  [ "$status" -ne 0 ]
}

# ecosystem-449.73. Counting wrapper for jq on PATH: each invocation appends one
# byte to $JQ_COUNT_FILE then delegates to the real binary, so the count is
# exact and behavior is unchanged. Same harness as
# test/bats/librarian-archivist-reader.bats, which pinned the identical defect
# one layer up.
_count_jq_spawns() {
  local real_jq
  real_jq=$(command -v jq)
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  export JQ_COUNT_FILE="${BATS_TEST_TMPDIR}/jq-count"
  : > "$JQ_COUNT_FILE"
  cat > "${STUB_BIN}/jq" <<STUB
#!/usr/bin/env bash
printf 'x' >> "${JQ_COUNT_FILE}"
exec "${real_jq}" "\$@"
STUB
  chmod +x "${STUB_BIN}/jq"
  export PATH="${STUB_BIN}:${PATH}"
}

_seed_ranked() {
  local key="$1" kind="$2" id="$3" at="${4:-2026-05-01T00:00:00Z}"
  printf '{"id":"%s","summary":"s","created_at":"%s","updated_at":"%s"}\n' "$id" "$at" "$at" \
    > "${ONLOOKER_DIR}/archivist/${key}/${kind}/${id}.json"
}

@test "load_ranked cost does not scale with the size of the artifact corpus" {
  # THE DEFECT. load_ranked spawned two jq processes per artifact -- one to
  # parse the file, and one more to re-parse and re-serialize the ENTIRE
  # accumulated array in order to append to it -- so the work was quadratic in
  # corpus size, not merely linear.
  #
  # Measured against the real corpus before the fix: 708 artifacts took
  # 23,756ms, against 42ms for 7. That is 100x the artifacts and 565x the time.
  # archivist-inject calls this on SessionStart, so its hook-health p50 went
  # from 380ms on 2026-09-12 to ~24,000ms on 09-13, the day commit mining
  # landed and the corpus began to grow. Wave 2's SessionStart exit criterion
  # is roughly 5s.
  #
  # Asserted as a subprocess count rather than a wall-clock budget: the cost IS
  # the spawns, and a count is exact on any machine under any load.
  local key="abc123def456"
  archivist_storage_init "$key"
  local i id
  for i in $(seq 1 60); do
    id="01ART$(printf '%021d' "$i")"
    _seed_ranked "$key" decisions "$id"
  done

  _count_jq_spawns

  local ranked
  ranked=$(archivist_storage_load_ranked "$key")
  [ "$(printf '%s' "$ranked" | jq 'length')" -eq 60 ] || return 1

  local spawns
  spawns=$(wc -c < "$JQ_COUNT_FILE" | tr -d ' ')
  # A handful of fixed calls is fine; anything proportional to 60 is the bug.
  [ "$spawns" -le 10 ]
}

@test "artifact content never travels through jq's argv" {
  # The 60-artifact test above passed while the function was still broken on
  # real data. The first fix accumulated each kind into a variable and combined
  # them with `jq -n --argjson decisions "$..."`, which puts the entire corpus
  # on the command line: on the real 708-artifact project that produced
  # "Argument list too long" and returned EMPTY. Fast and silently wrong.
  #
  # Corpus size alone is an unreliable trigger -- ARG_MAX is ~1MB on macOS and
  # ~2MB on Linux, so a fixture big enough to fail everywhere is big enough to
  # be slow everywhere. This pins the invariant instead: bulk data reaches jq on
  # stdin or as a FILE PATH, never as an argument value.
  local key="abc123def456"
  archivist_storage_init "$key"
  local i id
  for i in $(seq 1 12); do
    id="01ART$(printf '%021d' "$i")"
    _seed_ranked "$key" decisions "$id"
  done

  local real_jq
  real_jq=$(command -v jq)
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  export BIG_ARG_FILE="${BATS_TEST_TMPDIR}/big-arg"
  : > "$BIG_ARG_FILE"
  cat > "${STUB_BIN}/jq" <<STUB
#!/usr/bin/env bash
# A JSON blob passed as an argument is the defect. Real arguments here are jq
# programs, short flags, and file paths; none approach this size.
for a in "\$@"; do
  if [ "\${#a}" -gt 2000 ]; then
    printf '%s\n' "\${#a}" >> "${BIG_ARG_FILE}"
  fi
done
exec "${real_jq}" "\$@"
STUB
  chmod +x "${STUB_BIN}/jq"
  export PATH="${STUB_BIN}:${PATH}"

  local ranked
  ranked=$(archivist_storage_load_ranked "$key")
  [ "$(printf '%s' "$ranked" | jq 'length')" -eq 12 ] || return 1
  [ ! -s "$BIG_ARG_FILE" ]
}

@test "one malformed artifact does not blank the whole ranked set" {
  # A batch parse aborts on the first bad byte, so the fast path cannot be the
  # only path: one corrupt file would otherwise empty an entire injection.
  local key="abc123def456"
  archivist_storage_init "$key"
  _seed_ranked "$key" decisions "01GOOD"
  printf 'not json at all' > "${ONLOOKER_DIR}/archivist/${key}/decisions/01BAD.json"

  local ranked
  ranked=$(archivist_storage_load_ranked "$key")
  [ "$(printf '%s' "$ranked" | jq 'length')" -eq 1 ] || return 1
  [ "$(printf '%s' "$ranked" | jq -r '.[0].id')" = "01GOOD" ]
}

@test "load_ranked still tags each artifact with its kind" {
  # The kind is not in the file, it comes from the directory. A batch read that
  # loses that association would silently mislabel every artifact.
  local key="abc123def456"
  archivist_storage_init "$key"
  _seed_ranked "$key" decisions "01D" "2026-05-01T00:00:00Z"
  _seed_ranked "$key" open_questions "01Q" "2026-05-02T00:00:00Z"

  local ranked
  ranked=$(archivist_storage_load_ranked "$key")
  [ "$(printf '%s' "$ranked" | jq -r '.[] | select(.id=="01D") | .kind')" = "decisions" ] || return 1
  [ "$(printf '%s' "$ranked" | jq -r '.[] | select(.id=="01Q") | .kind')" = "open_questions" ]
}

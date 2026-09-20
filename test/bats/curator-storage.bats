#!/usr/bin/env bats
#
# curator_storage_load_findings reads a directory that grows without bound.
# Same quadratic-append shape as the archivist defect; pinned here before the
# corpus gets big enough to hurt. See ecosystem-449.74 / ONL-43.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/curator"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  source "${PLUGIN_ROOT}/scripts/lib/curator-storage.sh"

  KEY="abc123def456"
}

_seed_finding() {
  local key="$1" id="$2" hash="${3:-h$2}" status="${4:-open}"
  curator_storage_init "$key"
  # Sized like a real finding, which carries a detail string. See the note in
  # librarian-storage.bats: undersized fixtures make the argv test vacuous.
  local detail
  detail=$(printf 'memory path no longer resolves. %.0s' $(seq 1 12))
  jq -n --arg id "$id" --arg h "$hash" --arg status "$status" --arg detail "$detail" \
    '{id: $id, deduped_hash: $h, status: $status, kind: "date_decayed", detail: $detail}' \
    > "$(curator_findings_dir "$key")/${id}.json"
}

# Counts every jq process the function spawns. Same shape as the helper in
# archivist-storage.bats and librarian-archivist-reader.bats.
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

@test "load_findings returns every finding" {
  local i
  for i in $(seq 1 5); do
    _seed_finding "$KEY" "01FIND$(printf '%019d' "$i")"
  done

  local all
  all=$(curator_storage_load_findings "$KEY")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 5 ]
}

@test "load_findings returns [] for an unknown key" {
  local all
  all=$(curator_storage_load_findings "nosuchkey0000")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 0 ]
}

@test "load_findings cost does not scale with the size of the findings corpus" {
  # THE DEFECT. Two jq processes per finding -- one to parse the file, a second
  # to re-parse and re-serialize the ENTIRE accumulated array to append to it --
  # so work was quadratic in corpus size. Byte-identical in shape to the
  # archivist defect that took a 708-artifact read to 23,756ms.
  #
  # Asserted as a subprocess count, not a wall-clock budget: the cost IS the
  # spawns, and a count is exact on any machine under any load.
  local i
  for i in $(seq 1 60); do
    _seed_finding "$KEY" "01FIND$(printf '%019d' "$i")"
  done

  _count_jq_spawns

  local all
  all=$(curator_storage_load_findings "$KEY")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 60 ] || return 1

  local spawns
  spawns=$(wc -c < "$JQ_COUNT_FILE" | tr -d ' ')
  # A handful of fixed calls is fine; anything proportional to 60 is the bug.
  [ "$spawns" -le 10 ]
}

@test "finding content never travels through jq's argv" {
  # Pins the invariant the spawn-count test alone cannot: bulk data reaches jq
  # on stdin or as a FILE PATH, never as an argument value. Combining with
  # `jq -n --argjson all "$..."` would pass the count test and then return an
  # EMPTY result on a real corpus via "Argument list too long".
  local i
  for i in $(seq 1 12); do
    _seed_finding "$KEY" "01FIND$(printf '%019d' "$i")"
  done

  local real_jq
  real_jq=$(command -v jq)
  STUB_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB_BIN"
  export BIG_ARG_FILE="${BATS_TEST_TMPDIR}/big-arg"
  : > "$BIG_ARG_FILE"
  cat > "${STUB_BIN}/jq" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\${#a}" -gt 2000 ]; then
    printf '%s\n' "\${#a}" >> "${BIG_ARG_FILE}"
  fi
done
exec "${real_jq}" "\$@"
STUB
  chmod +x "${STUB_BIN}/jq"
  export PATH="${STUB_BIN}:${PATH}"

  local all
  all=$(curator_storage_load_findings "$KEY")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 12 ] || return 1
  [ ! -s "$BIG_ARG_FILE" ]
}

@test "one malformed finding does not blank the whole set" {
  # A batch jq aborts on the first malformed byte, so the per-file loop has to
  # survive as the fallback -- otherwise one corrupt file makes curator report
  # a clean store.
  local i
  for i in $(seq 1 4); do
    _seed_finding "$KEY" "01FIND$(printf '%019d' "$i")"
  done
  printf '{not json' > "$(curator_findings_dir "$KEY")/01FINDbroken.json"

  local all
  all=$(curator_storage_load_findings "$KEY")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 4 ]
}

@test "has_finding_with_hash still matches an open finding after the batch read" {
  _seed_finding "$KEY" "01FIND$(printf '%019d' 1)" "deadbeef" open
  _seed_finding "$KEY" "01FIND$(printf '%019d' 2)" "cafebabe" resolved

  curator_storage_has_finding_with_hash "$KEY" "deadbeef" || return 1
  ! curator_storage_has_finding_with_hash "$KEY" "cafebabe" || return 1
  ! curator_storage_has_finding_with_hash "$KEY" "nomatch00"
}

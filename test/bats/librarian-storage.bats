#!/usr/bin/env bats
#
# librarian_storage_load_proposals reads a directory that grows without bound:
# proposals persist until a human reviews them, and ecosystem-449.72 unblocked
# the classifier that fills it. This pins the cost invariants before the corpus
# gets big enough to hurt. See ecosystem-449.74 / ONL-43.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"

  KEY="abc123def456"
}

_seed_proposal() {
  local key="$1" id="$2" status="${3:-pending}"
  librarian_storage_init "$key"
  # Body sized like a real proposal (the classifier writes multi-paragraph
  # bodies). A 100-byte synthetic record is small enough that 12 of them fit
  # under the argv test's threshold, which let a --argjson design pass.
  local body
  body=$(printf 'why this memory is durable. %.0s' $(seq 1 12))
  jq -n --arg id "$id" --arg status "$status" --arg body "$body" \
    '{id: $id, status: $status, proposed: {type: "project", title: "t", body: $body}}' \
    > "$(librarian_proposals_dir "$key")/${id}.json"
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

@test "load_proposals returns every proposal" {
  local i
  for i in $(seq 1 5); do
    _seed_proposal "$KEY" "01PROP$(printf '%019d' "$i")"
  done

  local all
  all=$(librarian_storage_load_proposals "$KEY")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 5 ]
}

@test "load_proposals returns [] for an unknown key" {
  local all
  all=$(librarian_storage_load_proposals "nosuchkey0000")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 0 ]
}

@test "load_proposals cost does not scale with the size of the proposal corpus" {
  # THE DEFECT. The loop spawned two jq processes per proposal -- one to parse
  # the file, and a second to re-parse and re-serialize the ENTIRE accumulated
  # array in order to append to it -- so work was quadratic in corpus size.
  # Byte-identical in shape to the archivist defect that took 708 artifacts
  # from 42ms (at 7) to 23,756ms, and to the one ecosystem-449.68 fixed in
  # librarian's own copy of the archivist reader.
  #
  # Asserted as a subprocess count, not a wall-clock budget: the cost IS the
  # spawns, and a count is exact on any machine under any load.
  local i
  for i in $(seq 1 60); do
    _seed_proposal "$KEY" "01PROP$(printf '%019d' "$i")"
  done

  _count_jq_spawns

  local all
  all=$(librarian_storage_load_proposals "$KEY")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 60 ] || return 1

  local spawns
  spawns=$(wc -c < "$JQ_COUNT_FILE" | tr -d ' ')
  # A handful of fixed calls is fine; anything proportional to 60 is the bug.
  [ "$spawns" -le 10 ]
}

@test "proposal content never travels through jq's argv" {
  # The 60-proposal test above would still pass if the corpus were combined
  # with `jq -n --argjson all "$..."`, which puts the whole corpus on the
  # command line: on a large real project that yields "Argument list too long"
  # and an EMPTY result -- fast and silently wrong, worse than slow.
  #
  # Corpus size alone is an unreliable trigger (ARG_MAX is ~1MB on macOS,
  # ~2MB on Linux), so this pins the invariant instead: bulk data reaches jq
  # on stdin or as a FILE PATH, never as an argument value.
  local i
  for i in $(seq 1 12); do
    _seed_proposal "$KEY" "01PROP$(printf '%019d' "$i")"
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

  local all
  all=$(librarian_storage_load_proposals "$KEY")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 12 ] || return 1
  [ ! -s "$BIG_ARG_FILE" ]
}

@test "one malformed proposal does not blank the whole set" {
  # A batch jq aborts on the first malformed byte, so the per-file loop has to
  # survive as the fallback. Without it, a single corrupt file would return []
  # and the review queue would silently look empty.
  local i
  for i in $(seq 1 4); do
    _seed_proposal "$KEY" "01PROP$(printf '%019d' "$i")"
  done
  printf '{not json' > "$(librarian_proposals_dir "$KEY")/01PROPbroken.json"

  local all
  all=$(librarian_storage_load_proposals "$KEY")
  [ "$(printf '%s' "$all" | jq 'length')" -eq 4 ]
}

@test "count_pending counts only pending proposals" {
  _seed_proposal "$KEY" "01PROP$(printf '%019d' 1)" pending
  _seed_proposal "$KEY" "01PROP$(printf '%019d' 2)" pending
  _seed_proposal "$KEY" "01PROP$(printf '%019d' 3)" accepted

  [ "$(librarian_storage_count_pending "$KEY")" -eq 2 ]
}

#!/usr/bin/env bats
#
# curator_memory_load_all reads the whole typed memory store on every
# SessionStart, inside a 500ms scan budget. These tests pin the record shape and
# the fixed process count: one jq per file cost 2.5s at 51 memories, which spent
# the budget before any check could run.

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  source "${REPO_ROOT}/plugins/curator/scripts/lib/curator-memory-reader.sh"
  MEM_DIR="${BATS_TEST_TMPDIR}/memory"
  mkdir -p "$MEM_DIR"
}

_record() {
  local filename="$1"
  curator_memory_load_all "$MEM_DIR" | jq -c --arg f "$filename" '.[] | select(.filename == $f)'
}

# Counts jq starts while still running the real jq.
_count_jq() {
  local shim="${BATS_TEST_TMPDIR}/shim" real
  real=$(command -v jq)
  mkdir -p "$shim"
  cat >"${shim}/jq" <<EOF
#!/usr/bin/env bash
printf 'x\n' >>"${BATS_TEST_TMPDIR}/jq-starts"
exec "$real" "\$@"
EOF
  chmod +x "${shim}/jq"
  PATH="${shim}:${PATH}" curator_memory_load_all "$MEM_DIR" >"${BATS_TEST_TMPDIR}/loaded"
  wc -l <"${BATS_TEST_TMPDIR}/jq-starts" | tr -d ' '
}

@test "the number of jq starts does not grow with the store" {
  local i
  for i in 1 2 3; do printf -- '---\nname: m%s\n---\nbody\n' "$i" >"${MEM_DIR}/m${i}.md"; done
  local small
  small=$(_count_jq)

  rm -f "${BATS_TEST_TMPDIR}/jq-starts"
  for i in $(seq 4 40); do printf -- '---\nname: m%s\n---\nbody\n' "$i" >"${MEM_DIR}/m${i}.md"; done
  local large
  large=$(_count_jq)

  [ "$small" -eq "$large" ]
  [ "$(jq length "${BATS_TEST_TMPDIR}/loaded")" -eq 40 ]
}

@test "frontmatter fields and body land on the record" {
  printf -- '---\nname: a-memory\ndescription: why it matters\ntype: feedback\n---\n\nFirst line.\n\nLast line.\n\n\n' >"${MEM_DIR}/a.md"
  printf -- '- [A](a.md) — hook\n' >"${MEM_DIR}/MEMORY.md"

  run _record a.md
  [ "$status" -eq 0 ]
  [ "$(jq -r .title <<<"$output")" = "a-memory" ]
  [ "$(jq -r .description <<<"$output")" = "why it matters" ]
  [ "$(jq -r .type <<<"$output")" = "feedback" ]
  [ "$(jq -r .body <<<"$output")" = $'\nFirst line.\n\nLast line.' ]
  [ "$(jq -r .referenced <<<"$output")" = "true" ]
  [ "$(jq -r .frontmatter_parsed <<<"$output")" = "true" ]
}

@test "the first of a repeated frontmatter key wins, and body keys are not read" {
  printf -- '---\nname: first\nname: second\n---\ntype: feedback\n' >"${MEM_DIR}/a.md"

  run _record a.md
  [ "$(jq -r .title <<<"$output")" = "first" ]
  [ "$(jq -r .type <<<"$output")" = "null" ]
}

@test "a file with no trailing newline stays apart from the next file" {
  printf -- '---\nname: one\n---\nbody one' >"${MEM_DIR}/a.md"
  printf -- '---\nname: two\n---\nbody two' >"${MEM_DIR}/b.md"

  [ "$(_record a.md | jq -r .body)" = "body one" ]
  [ "$(_record b.md | jq -r .body)" = "body two" ]
}

@test "a file without frontmatter keeps its whole text as the body" {
  printf 'just text\n' >"${MEM_DIR}/a.md"

  run _record a.md
  [ "$(jq -r .body <<<"$output")" = "just text" ]
  [ "$(jq -r .title <<<"$output")" = "null" ]
  [ "$(jq -r .frontmatter_parsed <<<"$output")" = "false" ]
}

@test "unclosed frontmatter has no body" {
  printf -- '---\nname: open\nstill frontmatter\n' >"${MEM_DIR}/a.md"

  run _record a.md
  [ "$(jq -r .title <<<"$output")" = "open" ]
  [ "$(jq -r .body <<<"$output")" = "" ]
}

@test "an empty file is an existing record with an empty body" {
  : >"${MEM_DIR}/a.md"

  run _record a.md
  [ "$(jq -r .exists <<<"$output")" = "true" ]
  [ "$(jq -r .body <<<"$output")" = "" ]
}

@test "referenced files keep index order, then orphans follow" {
  printf 'x\n' >"${MEM_DIR}/a.md"
  printf 'x\n' >"${MEM_DIR}/b.md"
  printf 'x\n' >"${MEM_DIR}/c.md"
  printf -- '- [C](c.md) — x\n- [A](a.md) — x\n' >"${MEM_DIR}/MEMORY.md"

  run bash -c "source '${REPO_ROOT}/plugins/curator/scripts/lib/curator-memory-reader.sh'; curator_memory_load_all '${MEM_DIR}' | jq -c '[.[] | [.filename, .referenced]]'"
  [ "$output" = '[["c.md",true],["a.md",true],["b.md",false]]' ]
}

@test "a missing index entry has exists false and no description key" {
  printf -- '- [Gone](gone.md) — x\n' >"${MEM_DIR}/MEMORY.md"

  run _record gone.md
  [ "$(jq -r .exists <<<"$output")" = "false" ]
  [ "$(jq -r .referenced <<<"$output")" = "true" ]
  [ "$(jq -c 'has("description")' <<<"$output")" = "false" ]
}

@test "an unsafe index entry is marked and never read" {
  printf 'secret\n' >"${BATS_TEST_TMPDIR}/outside.md"
  printf -- '- [Out](../outside.md) — x\n' >"${MEM_DIR}/MEMORY.md"

  run _record ../outside.md
  [ "$(jq -r .unsafe <<<"$output")" = "true" ]
  [ "$(jq -r .exists <<<"$output")" = "false" ]
  [ "$(jq -r .body <<<"$output")" = "" ]
}

@test "a directory named like a memory is a missing record, not a failure" {
  mkdir "${MEM_DIR}/dir.md"
  printf 'x\n' >"${MEM_DIR}/a.md"
  printf -- '- [Dir](dir.md) — x\n- [A](a.md) — x\n' >"${MEM_DIR}/MEMORY.md"

  [ "$(_record dir.md | jq -r .exists)" = "false" ]
  [ "$(_record a.md | jq -r .exists)" = "true" ]
}

@test "an empty store loads as an empty array" {
  [ "$(curator_memory_load_all "$MEM_DIR" | jq -c .)" = "[]" ]
}

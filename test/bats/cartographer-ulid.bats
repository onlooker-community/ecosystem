#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/plugins/cartographer/scripts/lib/cartographer-ulid.sh"
}

@test "cartographer_ulid returns a 26-char Crockford Base32 string" {
  local id
  id=$(cartographer_ulid)
  [ "${#id}" -eq 26 ]
  [[ "$id" =~ ^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{26}$ ]]
}

@test "two ULIDs minted apart are lexicographically ordered" {
  local a b
  a=$(cartographer_ulid)
  sleep 0.01
  b=$(cartographer_ulid)
  [[ "$a" < "$b" ]] || [ "$a" = "$b" ]
}

@test "many ULIDs are unique" {
  local seen="${BATS_TEST_TMPDIR}/ulids.txt"
  : > "$seen"
  local i
  for ((i = 0; i < 50; i++)); do
    printf '%s\n' "$(cartographer_ulid)" >> "$seen"
  done
  local total unique
  total=$(wc -l < "$seen" | tr -d ' ')
  unique=$(sort -u "$seen" | wc -l | tr -d ' ')
  [ "$total" = "$unique" ]
}

@test "random component is 16 chars (full 80-bit coverage)" {
  local id
  id=$(cartographer_ulid)
  # Characters 10-25 (0-indexed) are the random component
  local rand_part="${id:10:16}"
  [ "${#rand_part}" -eq 16 ]
}

@test "timestamp component sorts ULIDs correctly across 10+ calls" {
  local prev=""
  local id
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    id=$(cartographer_ulid)
    if [[ -n "$prev" ]]; then
      [[ "$prev" < "$id" ]] || [ "$prev" = "$id" ]
    fi
    prev="$id"
  done
}

#!/usr/bin/env bats
#
# Exercises historian's chunker directly.
#
# The chunker splits on turn boundaries, which means a single long turn used
# to yield a single oversized chunk no matter what chunk_target_chars said.
# Those chunks are exactly the ones the embedder rejects (nomic-embed-text
# answers HTTP 500 above roughly 7k chars), so the most substantial turns in a
# session were the ones silently dropped from retrieval (ONL-123).
#
# The invariant these tests pin: no chunk body exceeds `target + overlap`, even
# when one turn is many times larger than the target. The ceiling is not the
# target itself because a chunk is seeded with the previous chunk's trailing
# `overlap` chars by design — on a real 8.5MB transcript that carry is what
# produces the largest chunks (2778 chars against a 2400 target).

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env

  PLUGIN_ROOT="${REPO_ROOT}/plugins/historian"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
  export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

  # shellcheck disable=SC1091
  source "${PLUGIN_ROOT}/scripts/lib/historian-chunker.sh"

  TARGET=2400
  OVERLAP=400
  # The hard ceiling every chunk must respect: a full target-sized window plus
  # the overlap carried in from the previous chunk, plus its "\n\n" joiner.
  CEILING=$((TARGET + OVERLAP + 2))
}

# Build a turns array. Each argument is "<role>:<char-count>", producing a turn
# whose content is that many repeated characters — distinct per turn so a split
# can be traced back to its source.
_turns() {
  python3 - "$@" <<'PY'
import json, sys

turns = []
alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
for i, spec in enumerate(sys.argv[1:]):
    role, count = spec.split(":")
    turns.append({
        "turn_index": i,
        "role": role,
        "content": alphabet[i % len(alphabet)] * int(count),
    })
print(json.dumps(turns))
PY
}

_max_body_chars() {
  jq -r '[.[].body_chars] | max'
}

@test "a turn far larger than the target is split into fitting chunks" {
  local turns out max count
  turns=$(_turns "user:20" "assistant:10000" "user:20")
  out=$(historian_chunker_split "$turns" "$TARGET" "$OVERLAP")

  max=$(printf '%s' "$out" | _max_body_chars)
  [ -n "$max" ] || return 1
  [ "$max" -le "$CEILING" ] || return 1

  # 10k chars cannot fit in one 2400-char chunk, so the oversized turn must
  # have produced several.
  count=$(printf '%s' "$out" | jq '[.[] | select(.start_turn_index == 1)] | length')
  [ "$count" -ge 4 ]
}

@test "every piece of a split turn is attributed to that turn" {
  local turns out bad
  turns=$(_turns "user:20" "assistant:10000" "user:20")
  out=$(historian_chunker_split "$turns" "$TARGET" "$OVERLAP")

  # A split piece covers exactly one turn, so start and end must agree.
  bad=$(printf '%s' "$out" \
    | jq '[.[] | select(.start_turn_index == 1 and .end_turn_index != 1)] | length')
  [ "$bad" -eq 0 ] || return 1

  # No piece may carry a null index — the store partitions on these.
  bad=$(printf '%s' "$out" \
    | jq '[.[] | select(.start_turn_index == null or .end_turn_index == null)] | length')
  [ "$bad" -eq 0 ]
}

@test "splitting preserves the oversized turn's content" {
  local turns out joined
  turns=$(_turns "assistant:10000")
  out=$(historian_chunker_split "$turns" "$TARGET" "$OVERLAP")

  # Overlap means pieces repeat text, so concatenation is a superset rather
  # than an exact match. What must hold is that no content is lost: every
  # one of the 10000 source characters is represented.
  joined=$(printf '%s' "$out" | jq -r '[.[].body] | join("")' | tr -cd 'A' | wc -c | tr -d ' ')
  [ "$joined" -ge 10000 ]
}

@test "chunk_index stays dense and ordered across a split" {
  local turns out
  turns=$(_turns "user:20" "assistant:10000" "user:20")
  out=$(historian_chunker_split "$turns" "$TARGET" "$OVERLAP")

  printf '%s' "$out" | jq -e 'to_entries | all(.value.chunk_index == .key)' >/dev/null
}

@test "body_chars matches the actual body length after a split" {
  local turns out bad
  turns=$(_turns "assistant:10000")
  out=$(historian_chunker_split "$turns" "$TARGET" "$OVERLAP")

  bad=$(printf '%s' "$out" | jq '[.[] | select(.body_chars != (.body | length))] | length')
  [ "$bad" -eq 0 ]
}

@test "turns that fit are still merged rather than split" {
  local turns out count max
  turns=$(_turns "user:300" "assistant:300" "user:300")
  out=$(historian_chunker_split "$turns" "$TARGET" "$OVERLAP")

  # Three small turns total well under the target, so they belong together.
  count=$(printf '%s' "$out" | jq 'length')
  [ "$count" -eq 1 ] || return 1

  max=$(printf '%s' "$out" | _max_body_chars)
  [ "$max" -le "$CEILING" ]
}

@test "a turn exactly at the target is not split" {
  local turns out count
  # Rendered form is "role: content", so back the content off by the prefix to
  # land exactly on the target.
  turns=$(_turns "user:$((TARGET - 6))")
  out=$(historian_chunker_split "$turns" "$TARGET" "$OVERLAP")

  count=$(printf '%s' "$out" | jq 'length')
  [ "$count" -eq 1 ]
}

@test "an overlap wider than the target still terminates" {
  local turns max
  # A misconfiguration: overlap >= target would give a non-positive stride and
  # could loop forever. The chunker must make progress regardless.
  turns=$(_turns "assistant:5000")
  run timeout 20 bash -c "
    source '${PLUGIN_ROOT}/scripts/lib/historian-chunker.sh'
    historian_chunker_split '$turns' 500 500
  "
  [ "$status" -eq 0 ] || return 1

  max=$(printf '%s' "$output" | _max_body_chars)
  [ "$max" -le 500 ]
}

@test "a chunk seeded with overlap still respects the ceiling" {
  local turns out max over

  # Turn 0 is oversized, so it sets pending_overlap. Turn 1 sits just under the
  # target, so its chunk is overlap + joiner + turn — the widest a chunk gets.
  turns=$(_turns "assistant:10000" "user:$((TARGET - 100))")
  out=$(historian_chunker_split "$turns" "$TARGET" "$OVERLAP")

  max=$(printf '%s' "$out" | _max_body_chars)
  [ "$max" -gt "$TARGET" ] || return 1     # the carry really does exceed target
  [ "$max" -le "$CEILING" ] || return 1

  # Whatever the carry does, nothing may reach the size the embedder rejects.
  over=$(printf '%s' "$out" | jq '[.[] | select(.body_chars > 7000)] | length')
  [ "$over" -eq 0 ]
}

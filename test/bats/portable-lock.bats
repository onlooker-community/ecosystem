#!/usr/bin/env bats

setup() {
  # shellcheck source=../helpers/setup.bash
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/scripts/lib/portable-lock.sh"
  LOCK="${BATS_TEST_TMPDIR}/test.lock"
}

@test "lock_acquire succeeds on an unlocked path" {
  run lock_acquire "$LOCK" 1
  [ "$status" -eq 0 ]
  [ -d "${LOCK}.d" ]
  lock_release "$LOCK"
}

@test "lock_acquire on a held lock blocks until released" {
  lock_acquire "$LOCK" 1
  # Start a background releaser after 200ms.
  ( sleep 0.2; lock_release "$LOCK" ) &
  local releaser=$!
  # Second acquire should succeed once the releaser fires.
  run lock_acquire "$LOCK" 2
  wait $releaser
  [ "$status" -eq 0 ]
  lock_release "$LOCK"
}

@test "lock_acquire returns 1 when timeout elapses with the lock still held" {
  mkdir "${LOCK}.d"
  run lock_acquire "$LOCK" 1
  [ "$status" -eq 1 ]
  rmdir "${LOCK}.d"
}

@test "lock_release is a no-op when the lock is not held" {
  run lock_release "$LOCK"
  [ "$status" -eq 0 ]
}

@test "concurrent appenders do not interleave writes" {
  local out="${BATS_TEST_TMPDIR}/concurrent.txt"
  : >"$out"
  local n=20
  local i
  for ((i = 0; i < n; i++)); do
    (
      lock_acquire "$LOCK" 5 || exit 1
      # Write a 100-char marker so any byte-level interleave is obvious.
      printf '%s\n' "$(printf 'x%.0s' {1..100})" >>"$out"
      lock_release "$LOCK"
    ) &
  done
  wait
  # All lines should be exactly 100 bytes followed by newline.
  local lines
  lines=$(wc -l <"$out" | tr -d ' ')
  [ "$lines" = "$n" ]
  awk 'length($0) != 100 { bad++ } END { exit (bad > 0) }' "$out"
}

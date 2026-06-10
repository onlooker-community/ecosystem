#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
  setup_test_env
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/plugins/cartographer/scripts/lib/cartographer-lock.sh"

  LOCK_FILE="${BATS_TEST_TMPDIR}/test.lock"
}

teardown() {
  cartographer_lock_release "$LOCK_FILE" 2>/dev/null || true
}

@test "acquire succeeds when lock is free" {
  run cartographer_lock_acquire "$LOCK_FILE"
  [ "$status" -eq 0 ]
}

@test "acquire fails immediately when lock is already held" {
  cartographer_lock_acquire "$LOCK_FILE"
  run cartographer_lock_acquire "$LOCK_FILE"
  [ "$status" -ne 0 ]
}

@test "release allows re-acquire" {
  cartographer_lock_acquire "$LOCK_FILE"
  cartographer_lock_release "$LOCK_FILE"
  run cartographer_lock_acquire "$LOCK_FILE"
  [ "$status" -eq 0 ]
}

@test "is_held returns true while lock is held" {
  cartographer_lock_acquire "$LOCK_FILE"
  run cartographer_lock_is_held "$LOCK_FILE"
  [ "$status" -eq 0 ]
}

@test "is_held returns false after release" {
  cartographer_lock_acquire "$LOCK_FILE"
  cartographer_lock_release "$LOCK_FILE"
  run cartographer_lock_is_held "$LOCK_FILE"
  [ "$status" -ne 0 ]
}

@test "release is idempotent (safe to call when not held)" {
  run cartographer_lock_release "$LOCK_FILE"
  [ "$status" -eq 0 ]
}

@test "two independent lock paths do not interfere" {
  local lock_a="${BATS_TEST_TMPDIR}/a.lock"
  local lock_b="${BATS_TEST_TMPDIR}/b.lock"
  cartographer_lock_acquire "$lock_a"
  run cartographer_lock_acquire "$lock_b"
  [ "$status" -eq 0 ]
  cartographer_lock_release "$lock_a"
  cartographer_lock_release "$lock_b"
}

@test "background child holds lock after parent releases its reference" {
  # Acquire in a background subprocess, then verify is_held from this process.
  bash -c "
    source '${REPO_ROOT}/plugins/cartographer/scripts/lib/cartographer-lock.sh'
    cartographer_lock_acquire '${LOCK_FILE}'
    sleep 2
    cartographer_lock_release '${LOCK_FILE}'
  " &
  sleep 0.1
  run cartographer_lock_is_held "$LOCK_FILE"
  [ "$status" -eq 0 ]
  # Second acquire from this process must fail while child holds it
  run cartographer_lock_acquire "$LOCK_FILE"
  [ "$status" -ne 0 ]
  wait
}

@test "missing vendored portable-lock.sh degrades to a no-op lock, never crashes" {
  # Copy only the wrapper into an isolated dir WITHOUT its sibling
  # portable-lock.sh to simulate a broken packaging/path. The cartographer
  # hooks are fail-soft (exit 0), so sourcing must not abort and acquire must
  # fail so the caller's `... || exit 0` skips the audit instead of crashing.
  cp "${REPO_ROOT}/plugins/cartographer/scripts/lib/cartographer-lock.sh" "${BATS_TEST_TMPDIR}/cartographer-lock.sh"
  run bash -c "
    source '${BATS_TEST_TMPDIR}/cartographer-lock.sh'
    echo SOURCED_OK
    cartographer_lock_acquire '${BATS_TEST_TMPDIR}/x.lock' && echo ACQUIRED || echo ACQUIRE_FAILED
    cartographer_lock_release '${BATS_TEST_TMPDIR}/x.lock' && echo RELEASE_OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED_OK"* ]]
  [[ "$output" == *"ACQUIRE_FAILED"* ]]
  [[ "$output" == *"RELEASE_OK"* ]]
  [[ "$output" == *"locking disabled"* ]]
}

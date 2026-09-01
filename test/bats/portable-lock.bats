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

# --- stale-lock breaking (ecosystem-am1) -----------------------------------
#
# lock_release runs from an EXIT trap, which bash fires on normal exit,
# SIGTERM, and SIGINT — but not on SIGKILL or a hard harness timeout. Without
# a breaker, one killed holder wedges the lock for the rest of the session:
# every later acquire waits the full timeout and gives up. These cover the
# three ways a lock can look abandoned.

# A pid that is guaranteed not to be running: start a process, reap it, reuse
# its number. Cheaper and more deterministic than picking a high number and
# hoping.
_dead_pid() {
  local p
  sleep 0 &
  p=$!
  wait "$p" 2>/dev/null || true
  printf '%s' "$p"
}

_seed_lock() {
  local holder="${1-}"
  mkdir "${LOCK}.d"
  [[ -n "$holder" ]] && printf '%s\n' "$holder" >"${LOCK}.d/holder"
  return 0
}

@test "a lock whose holder process is gone is broken and re-acquired" {
  _seed_lock "$(_dead_pid)"
  run lock_acquire "$LOCK" 5
  [ "$status" -eq 0 ] || return 1
  [ -d "${LOCK}.d" ] || return 1
  lock_release "$LOCK"
}

@test "a lock held by a live process is never broken" {
  sleep 5 &
  local live=$!
  _seed_lock "$live"
  run lock_acquire "$LOCK" 1
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  rm -rf "${LOCK}.d"
  [ "$status" -eq 1 ]
}

@test "a lock with no holder metadata is broken once the stale window elapses" {
  _seed_lock ""
  run lock_acquire "$LOCK" 5 1
  [ "$status" -eq 0 ] || return 1
  lock_release "$LOCK"
}

@test "a lock with no holder metadata survives while it is still fresh" {
  _seed_lock ""
  run lock_acquire "$LOCK" 1 30
  rm -rf "${LOCK}.d"
  [ "$status" -eq 1 ]
}

@test "an acquired lock records the holder pid so a waiter can judge it" {
  lock_acquire "$LOCK" 1
  run cat "${LOCK}.d/holder"
  lock_release "$LOCK"
  [ "$output" = "$$" ] || return 1
  [ "$status" -eq 0 ]
}

@test "lock_release removes the lock directory and its holder metadata" {
  lock_acquire "$LOCK" 1
  lock_release "$LOCK"
  [ ! -e "${LOCK}.d" ]
}

@test "lock_release leaves a lock that a waiter already broke and re-took" {
  # Our own stale lock was broken and re-acquired by another process; our
  # late release must not evict the new holder.
  _seed_lock "$(_dead_pid)"
  run lock_release "$LOCK"
  [ -d "${LOCK}.d" ] || return 1
  rm -rf "${LOCK}.d"
  [ "$status" -eq 0 ]
}

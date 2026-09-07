#!/usr/bin/env bats

# The audit lock, exercised through run-audit.sh rather than portable-lock.
#
# ecosystem-hap. The lock used to be taken by the launching hook, which then
# backgrounded the audit and exited within ~2s. portable-lock stamps the holder
# pid at acquire time, so the recorded holder was already gone and the next
# caller's staleness check reclaimed the lock on its first try — it excluded
# nothing. Release was broken in the opposite direction: the launcher set an
# EXIT trap and then `exec`ed run-audit.sh, which replaces the process image and
# discards traps, so nothing ever released it.
#
# The two defects cancelled, which is why neither was visible. That is also why
# these tests drive the real script: a unit test of portable-lock passes
# happily while the caller holds it wrong.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	AUDIT="${PLUGIN_ROOT}/scripts/run-audit.sh"

	FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${FIXTURE_REPO}/.claude"
	printf '# Root\nAlways read scripts/lib/config-loader.sh first.\n' > "${FIXTURE_REPO}/CLAUDE.md"

	export CARTOGRAPHER_DIR="${BATS_TEST_TMPDIR}/cartographer"
	mkdir -p "$CARTOGRAPHER_DIR"
	LOCK_FILE="${CARTOGRAPHER_DIR}/audit.lock"
	export CARTOGRAPHER_REPO_ROOT="$FIXTURE_REPO"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '[]'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	source "${PLUGIN_ROOT}/scripts/lib/cartographer-lock.sh"
}

_run_audit() {
	CARTOGRAPHER_TRIGGER="${1:-manual}" bash "$AUDIT" >>"${CARTOGRAPHER_DIR}/audit.log" 2>&1
}

@test "an audit releases its lock when it finishes" {
	_run_audit
	[ ! -d "${LOCK_FILE}.d" ]
}

# The failure this replaces: the launcher's EXIT trap sat above an `exec`, so
# the release never ran at all and a lock directory survived every audit.
@test "an audit releases its lock even when a phase fails" {
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
exit 3
STUB
	chmod +x "${STUB_BIN}/claude"
	_run_audit || true
	[ ! -d "${LOCK_FILE}.d" ]
}

# The exclusion half. A LIVE holder must block a second audit — the old code
# recorded a dead one, so this always passed the lock straight through.
@test "a second audit declines while a live holder holds the lock" {
	# A real live process as the holder, not a fabricated pid: staleness is
	# decided by kill -0, so only a genuinely running process proves exclusion.
	sleep 30 &
	local holder=$!
	mkdir -p "${LOCK_FILE}.d"
	printf '%s\n' "$holder" > "${LOCK_FILE}.d/holder"

	run _run_audit
	kill "$holder" 2>/dev/null || true

	[ "$status" -eq 0 ] || return 1
	grep -q 'another audit holds' "${CARTOGRAPHER_DIR}/audit.log" || return 1
	# The live holder's lock must survive our declined attempt.
	[ -d "${LOCK_FILE}.d" ]
}

# ...but a holder that died without releasing must not wedge cartographer
# forever. This is the reason the exclusion fix cannot ship on its own.
@test "a lock abandoned by a dead holder is reclaimed, not deadlocked" {
	sleep 0.1 &
	local dead=$!
	wait "$dead" 2>/dev/null || true
	mkdir -p "${LOCK_FILE}.d"
	printf '%s\n' "$dead" > "${LOCK_FILE}.d/holder"

	_run_audit
	# Reclaimed, used, and released again.
	[ ! -d "${LOCK_FILE}.d" ]
}

@test "the holder recorded is the audit process, not the caller" {
	# Proven by outcome rather than by reading the file mid-run: if the caller's
	# pid were recorded, it would be dead the moment the audit backgrounds and a
	# concurrent audit would sail through. Here the caller stays alive and the
	# audit has finished, so a fresh acquire must succeed on a released lock.
	_run_audit
	[ ! -d "${LOCK_FILE}.d" ] || return 1
	cartographer_lock_acquire "$LOCK_FILE"
	[ -d "${LOCK_FILE}.d" ] || return 1
	cartographer_lock_release "$LOCK_FILE"
	[ ! -d "${LOCK_FILE}.d" ]
}

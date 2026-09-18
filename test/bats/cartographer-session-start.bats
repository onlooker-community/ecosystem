#!/usr/bin/env bats
# Cartographer reporting that its undocumented_entity globs can never match
# (ecosystem-449.21).
#
# Nothing drove this hook before this file. Every test below pins last_audit_at
# to now, so the interval gate returns and no detached audit is spawned -- which
# is also the condition the check most needs to survive, since a throttled audit
# is exactly when a dead config would otherwise stay invisible.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/cartographer-session-start.sh"

	FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${FIXTURE_REPO}/.claude"
	git -C "$FIXTURE_REPO" init -q
	git -C "$FIXTURE_REPO" config user.email test@example.com
	git -C "$FIXTURE_REPO" config user.name test
	git -C "$FIXTURE_REPO" remote add origin git@github.com:org/fixture.git
	printf '# Root\n' >"${FIXTURE_REPO}/CLAUDE.md"
	git -C "$FIXTURE_REPO" add -A
	git -C "$FIXTURE_REPO" commit -qm init

	source "${PLUGIN_ROOT}/scripts/lib/cartographer-project-key.sh"
	PROJECT_KEY=$(cartographer_project_key "$FIXTURE_REPO")
	mkdir -p "${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}"
	# Interval gate returns: no audit is ever spawned by these tests.
	date +%s >"${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}/last_audit_at"
}

_settings() {
	printf '%s\n' "$1" >"${FIXTURE_REPO}/.claude/settings.json"
}

_run_hook() {
	run bash -c "printf '%s' '$(jq -cn --arg cwd "$FIXTURE_REPO" \
		'{cwd: $cwd, session_id: "sess-carto", hook_event_name: "SessionStart", source: "startup"}')' | '$HOOK'"
}

@test "reports when undocumented_entity globs can never match" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	grep '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.plugin == "cartographer"
		         and .payload.config_key == "cartographer.undocumented_entity.globs"
		         and .payload.patterns == ["nowhere/*/"]' >/dev/null
}

# PLACEMENT CHECK. last_audit_at is pinned to now in setup, so the hook returns
# at the interval gate. The report must precede that return.
@test "reports even though the audit interval has not elapsed" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	[ "$status" -eq 0 ]
	grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "stays quiet when globs match real directories" {
	mkdir -p "${FIXTURE_REPO}/plugins/demo"
	_settings '{"cartographer":{"undocumented_entity":{"globs":["plugins/*/"]}}}'
	_run_hook
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

# The divergence from echo, exercised end to end: an untracked directory is a
# match for cartographer because its matcher expands against the filesystem.
@test "an untracked directory counts as a match" {
	mkdir -p "${FIXTURE_REPO}/untracked/child"
	printf 'untracked/\n' >"${FIXTURE_REPO}/.gitignore"
	_settings '{"cartographer":{"undocumented_entity":{"globs":["untracked/*/"]}}}'
	_run_hook
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

# A dead config and a feature switched off deliberately look identical to a
# glob scan -- both match zero paths -- but only one of them is a
# misconfiguration. run-audit.sh itself declines to run the undocumented_entity
# phase when it is disabled (run-audit.sh:254); the watch check must decline
# the same way, or it reports a feature the user turned off as a dead plugin.
@test "stays quiet when undocumented_entity is disabled, even though its globs match nothing" {
	_settings '{"cartographer":{"undocumented_entity":{"enabled":false,"globs":["nowhere/*/"]}}}'
	_run_hook
	[ "$status" -eq 0 ]
	! grep -q '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG"
}

@test "emits once across two sessions, not once per SessionStart" {
	_settings '{"cartographer":{"undocumented_entity":{"globs":["nowhere/*/"]}}}'
	_run_hook
	_run_hook
	count=$(grep -c '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG")
	[[ "$count" == "1" ]]
}

# ecosystem-449.62 — the spawn gate, end to end.
#
# Every test above pins last_audit_at to now so the interval gate returns before
# the lock check. These two do the opposite: the interval HAS elapsed, so the
# lock probe is the last thing standing between the session and an audit.
#
# The bug these replace: the probe was `[[ -d "${lock}.d" ]]`, so any lock
# directory — including one left by an audit that was killed months ago — made
# the hook exit. run-audit.sh's acquire would have broken that lock on its first
# iteration, but the hook exited before spawning it. 20 of 23 project directories
# on the author's machine were wedged this way, the oldest since June.

_stale_lock_setup() {
	CARTO_DIR="${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}"
	LOCK_D="${CARTO_DIR}/audit.lock.d"
	# Interval elapsed: the hook must reach the lock probe.
	printf '0\n' >"${CARTO_DIR}/last_audit_at"
	_settings '{"cartographer":{"undocumented_entity":{"globs":["plugins/*/"]}}}'

	# run-audit.sh shells out to claude; keep it deterministic and instant.
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	printf '#!/usr/bin/env bash\ncat >/dev/null\nprintf %s "[]"\n' >"${STUB_BIN}/claude"
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

# Asserted through the lock's disappearance rather than through audit.log: the
# lock can only be cleared by the audit process, so a cleared lock is proof the
# hook spawned it. The audit is detached, hence the bounded wait.
_wait_for_lock_release() {
	local waited=0
	while [[ -d "$LOCK_D" && "$waited" -lt 20 ]]; do
		sleep 1
		waited=$((waited + 1))
	done
}

@test "a lock abandoned by a dead audit does not stop the next session auditing" {
	_stale_lock_setup
	# No holder file — the shape left by pre-holder-file code, and the shape
	# every stranded lock on the author's machine actually had.
	mkdir -p "$LOCK_D"

	_run_hook
	[ "$status" -eq 0 ] || return 1
	_wait_for_lock_release
	[ ! -d "$LOCK_D" ]
}

# The other half, so the fix cannot pass by simply never gating.
#
# Asserted on whether an audit was SPAWNED, not on whether the lock survived.
# The lock survives either way — run-audit.sh declines a live holder on its own
# — so a surviving lock proves nothing about this gate. The first draft of this
# test made that mistake and a `return 1` mutant (never gate at all) passed it.
# A spawned audit announces its decline in audit.log; a gated one writes nothing.
@test "a lock held by a live audit still turns the next session away" {
	_stale_lock_setup
	sleep 30 &
	local holder=$!
	mkdir -p "$LOCK_D"
	printf '%s\n' "$holder" >"${LOCK_D}/holder"

	_run_hook
	# Generous next to the ~100ms a spawned audit needs to reach the lock.
	sleep 2
	local spawned=0
	grep -q 'another audit holds' "${CARTO_DIR}/audit.log" 2>/dev/null && spawned=1
	kill "$holder" 2>/dev/null || true

	[ "$spawned" -eq 0 ] || return 1
	[ -d "$LOCK_D" ]
}

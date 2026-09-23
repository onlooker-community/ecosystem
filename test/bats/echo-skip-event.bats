#!/usr/bin/env bats

# Echo deciding NOT to score was invisible (ecosystem-449.40 acceptance 7,
# ecosystem-449.52 gap 1).
#
# The only signal was the ABSENCE of echo.suite.started, which cannot tell
# "nothing was dirty" from "everything dirty was already scored" from "the hook
# never fired". That ambiguity is exactly why the 449.40 re-measure could not be
# read off the bus: the content-hash filter's whole job is to skip work, and its
# success looked identical to the hook not running.
#
# echo.suite.skipped (schema 2.21.0) names which. All three silent exits emit
# it, not just the content-unchanged one — covering only that case would leave
# the ambiguity half-open, since absence would still mean either of the other
# two.
#
# Two more silent exits were found later, downstream of the ones above (ONL-101).
# A suite that has already emitted echo.suite.started can still score nothing:
# every file suppressed post-judge as already-scored by a concurrent session
# (the ecosystem-449.46 check), or every judge call returning nothing usable.
# Both fell out of `[[ $file_count -eq 0 ]] && _done`, which sits BEFORE the
# echo.suite.complete emit — so the suite's only trace was a started event with
# no terminator at all. Measured 2026-09-19: nine started, three complete.
# Those exits carry suite_id (schema 2.22.0), because a terminator that cannot
# name the suite it closes is not one.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/echo-stop-gate.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${REPO}/agents" "${REPO}/src" "${REPO}/.claude"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	printf '# Agent\n\nCOMMITTED BODY\n' > "${REPO}/agents/reviewer.md"
	printf 'committed\n' > "${REPO}/src/unwatched.txt"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm init
	printf '%s\n' '{"echo":{"watch_paths":["agents/*.md"]}}' > "${REPO}/.claude/settings.json"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm settings

	# Paths only — deliberately no baseline file. The content_unchanged tests
	# below depend on the first run being a first evaluation.
	source "${PLUGIN_ROOT}/scripts/lib/echo-project-key.sh"
	PROJECT_KEY=$(echo_project_key "$REPO")
	BASELINE_DIR="${ONLOOKER_DIR}/echo/${PROJECT_KEY}/baselines"
	TEST_ID=$(echo_test_id_for_path "agents/reviewer.md")
	BASELINE_FILE="${BASELINE_DIR}/${TEST_ID}.json"
	mkdir -p "$BASELINE_DIR"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '{"score":0.80,"passed":true,"confidence":0.9,"feedback":"stub"}'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

# A baseline scored from the COMMITTED bytes, so an edited file still looks
# changed to the pre-judge filter and the suite genuinely starts.
_baseline_from_committed_bytes() {
	local sha
	sha=$(git -C "$REPO" show HEAD:agents/reviewer.md | shasum -a 256 | cut -d' ' -f1)
	jq -n --arg path "agents/reviewer.md" --arg test_id "$TEST_ID" \
		--arg sha "$sha" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{path: $path, test_id: $test_id, score: 0.64,
		  content_sha256: $sha, recorded_at: $ts}' > "$BASELINE_FILE"
}

# Stands in for a concurrent session that finished its judge first: while our
# hook is inside its own claude call, the baseline is rewritten stamped with
# the bytes our hook is judging right now. Our post-judge re-read then finds
# RECORDED_SHA == JUDGED_SHA and suppresses (ecosystem-449.46), which is the
# real path — no sleeps, no ordering race.
_stub_claude_that_loses_the_race() {
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null
sha=\$(shasum -a 256 "${REPO}/agents/reviewer.md" | cut -d' ' -f1)
jq -n --arg path "agents/reviewer.md" --arg test_id "${TEST_ID}" \\
	--arg sha "\$sha" --arg ts "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
	'{path: \$path, test_id: \$test_id, score: 0.86,
	  content_sha256: \$sha, recorded_at: \$ts}' > "${BASELINE_FILE}"
printf '{"score":0.86,"passed":true,"confidence":0.9,"feedback":"stub"}'
STUB
	chmod +x "${STUB_BIN}/claude"
}

_run_hook() {
	local input
	input=$(jq -n --arg cwd "$REPO" --arg sid "${1:-sess-echo-skip}" \
		'{cwd: $cwd, session_id: $sid}')
	run bash -c "printf '%s' '$input' | '$HOOK'"
}

_skip_reason() {
	[ -f "$ONLOOKER_EVENTS_LOG" ] || return 1
	grep '"event_type":"echo.suite.skipped"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null \
		| tail -n 1 | jq -r '.payload.reason // empty'
}

_has_event() {
	[ -f "$ONLOOKER_EVENTS_LOG" ] || return 1
	grep -q "\"event_type\":\"$1\"" "$ONLOOKER_EVENTS_LOG"
}

@test "a clean tree says nothing changed" {
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[[ "$(_skip_reason)" == "no_changes" ]]
}

@test "a dirty tree with nothing watched says so" {
	# The unwatched file is dirty, so the hook gets past the no-changes exit
	# and stops at the watch filter instead.
	printf 'edited\n' > "${REPO}/src/unwatched.txt"
	_run_hook
	[ "$status" -eq 0 ] || return 1
	[[ "$(_skip_reason)" == "no_watched_changes" ]]
}

@test "an already-scored watched file says the content is unchanged" {
	# First Stop scores it; the second sees the same bytes. That second exit is
	# the one ecosystem-449.40 created and could not observe.
	printf '# Agent\n\nEDITED\n' > "${REPO}/agents/reviewer.md"
	_run_hook "sess-1"
	_has_event "echo.suite.started" || return 1

	rm -f "$ONLOOKER_EVENTS_LOG"
	_run_hook "sess-2"
	[ "$status" -eq 0 ] || return 1
	[[ "$(_skip_reason)" == "content_unchanged" ]] || return 1
	# And it really did skip the work, not merely label it.
	! _has_event "echo.suite.started" || return 1
}

@test "the content-unchanged skip reports what it considered" {
	printf '# Agent\n\nEDITED\n' > "${REPO}/agents/reviewer.md"
	_run_hook "sess-1"
	rm -f "$ONLOOKER_EVENTS_LOG"
	_run_hook "sess-2"

	local ev
	ev=$(grep '"event_type":"echo.suite.skipped"' "$ONLOOKER_EVENTS_LOG" | tail -n 1)
	printf '%s' "$ev" | jq -e '.payload.considered_count == 1' >/dev/null || return 1
	printf '%s' "$ev" | jq -e '.payload.changed_file == "agents/reviewer.md"' >/dev/null
}

@test "real work still starts a suite rather than emitting a skip" {
	# Regression pin: the skip must not fire on the path that does the work.
	printf '# Agent\n\nEDITED\n' > "${REPO}/agents/reviewer.md"
	_run_hook
	[ "$status" -eq 0 ] || return 1
	_has_event "echo.suite.started" || return 1
	! _has_event "echo.suite.skipped" || return 1
}

# --- ONL-101: a suite that started and scored nothing still terminates -------

_skipped_event() {
	grep '"event_type":"echo.suite.skipped"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null | tail -n 1
}

_started_suite_id() {
	grep '"event_type":"echo.suite.started"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null \
		| tail -n 1 | jq -r '.payload.suite_id // empty'
}

@test "a suite whose every file was suppressed says so instead of going quiet" {
	# The expensive case: the judge was paid for, then a concurrent session
	# turned out to have scored identical bytes first. Before ONL-101 this
	# emitted started and nothing else.
	_baseline_from_committed_bytes
	_stub_claude_that_loses_the_race
	printf '# Agent\n\nEDITED\n' > "${REPO}/agents/reviewer.md"

	_run_hook "sess-suppressed"
	[ "$status" -eq 0 ] || return 1
	_has_event "echo.suite.started" || return 1
	[[ "$(_skip_reason)" == "all_suppressed" ]]
}

@test "the suppressed terminator names the suite it closes" {
	# Without suite_id the event cannot be joined to its started event, which
	# is the only reason to emit a terminator rather than stay silent.
	_baseline_from_committed_bytes
	_stub_claude_that_loses_the_race
	printf '# Agent\n\nEDITED\n' > "${REPO}/agents/reviewer.md"

	_run_hook "sess-suppressed-id"
	local started
	started=$(_started_suite_id)
	[ -n "$started" ] || return 1
	printf '%s' "$(_skipped_event)" | jq -e --arg s "$started" '.payload.suite_id == $s' >/dev/null
}

@test "a suite whose judge returned nothing usable says that, not suppressed" {
	# Distinct cause, distinct reason. Collapsing this into all_suppressed
	# would hide a broken judge behind a working optimization.
	_baseline_from_committed_bytes
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf ''
STUB
	chmod +x "${STUB_BIN}/claude"
	printf '# Agent\n\nEDITED\n' > "${REPO}/agents/reviewer.md"

	_run_hook "sess-unscorable"
	[ "$status" -eq 0 ] || return 1
	_has_event "echo.suite.started" || return 1
	[[ "$(_skip_reason)" == "no_scorable_files" ]]
}

@test "a suite that really scored something still completes rather than terminating early" {
	# Over-fix guard: the new exits must not swallow the working path.
	_baseline_from_committed_bytes
	printf '# Agent\n\nEDITED\n' > "${REPO}/agents/reviewer.md"

	_run_hook "sess-real"
	[ "$status" -eq 0 ] || return 1
	_has_event "echo.suite.complete" || return 1
	! _has_event "echo.suite.skipped" || return 1
}

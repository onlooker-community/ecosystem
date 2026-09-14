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

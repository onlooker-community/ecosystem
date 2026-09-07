#!/usr/bin/env bats

# Echo re-scores unchanged files on every Stop (ecosystem-449.40).
#
# The trigger at echo-stop-gate.sh:98-100 is "dirty relative to HEAD", not
# "changed since the last evaluation", and the baseline record carries no
# content hash. So one edit to a watched file re-runs a 26-48s claude -p on
# every subsequent Stop until that file is committed, and each run overwrites
# the baseline with a fresh sample of the same content.
#
# Both halves of that hurt, and they need separating:
#
#   COST     the repeat evaluations are the top line item in the whole hook
#            stack -- 265s of blocked Stop time in one day, over two files.
#   CORRECTNESS a single judge's spread on identical content was measured at
#            0.13-0.24 against a drift_threshold of 0.05, so the repeats
#            report regressions and improvements for content that never moved.
#
# The stub below returns a DIFFERENT score on each call. That is the whole
# point: it stands in for judge noise, so a hook that re-evaluates unchanged
# content cannot help but emit a verdict, and a hook that skips it emits
# nothing. Tests that assert on cost (claude call count) and on correctness
# (no drift events) are kept separate so a fix cannot satisfy one by accident.

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
	mkdir -p "${REPO}/agents" "${REPO}/.claude"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	printf '# Agent\n\nCOMMITTED BODY\n' > "${REPO}/agents/reviewer.md"
	git -C "$REPO" add -A
	git -C "$REPO" commit -qm init
	printf '%s\n' '{"echo":{"watch_paths":["agents/*.md"]}}' > "${REPO}/.claude/settings.json"

	source "${PLUGIN_ROOT}/scripts/lib/echo-project-key.sh"
	PROJECT_KEY=$(echo_project_key "$REPO")
	BASELINE_DIR="${ONLOOKER_DIR}/echo/${PROJECT_KEY}/baselines"
	TEST_ID=$(echo_test_id_for_path "agents/reviewer.md")
	BASELINE_FILE="${BASELINE_DIR}/${TEST_ID}.json"

	# One call per line, and a different score each time — the scores step
	# 0.80, 0.60, 0.90 so any repeat evaluation crosses the 0.05 default
	# drift_threshold in both directions.
	CLAUDE_MARKER="${BATS_TEST_TMPDIR}/claude-calls"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf 'call\n' >> "${CLAUDE_MARKER}"
case \$(wc -l < "${CLAUDE_MARKER}" | tr -d ' ') in
	1) score=0.80 ;;
	2) score=0.60 ;;
	*) score=0.90 ;;
esac
printf '{"score":%s,"passed":true,"confidence":0.9,"feedback":"stub"}' "\$score"
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

_claude_calls() {
	[ -f "$CLAUDE_MARKER" ] || { printf '0'; return 0; }
	wc -l < "$CLAUDE_MARKER" | tr -d ' '
}

_drift_events() {
	[ -f "$ONLOOKER_EVENTS_LOG" ] || { printf '0'; return 0; }
	# grep -c prints 0 and exits 1 on no match, so capture first, then default.
	local n
	n=$(grep -c '"event_type":"echo\.\(regression\|improvement\)\.detected"' \
		"$ONLOOKER_EVENTS_LOG" 2>/dev/null) || n=0
	printf '%s' "$n"
}

_dirty_the_file() {
	printf '# Agent\n\n%s\n' "$1" > "${REPO}/agents/reviewer.md"
}

@test "a dirty file is evaluated once, not again on the next Stop" {
	# The cost half. Two Stops, one edit: the second Stop sees the same bytes
	# the baseline was scored from and has no reason to spend a judge on them.
	_dirty_the_file "EDITED ONCE"
	_run_hook "sess-1"
	[ "$(_claude_calls)" -eq 1 ] || return 1

	_run_hook "sess-2"
	[ "$(_claude_calls)" -eq 1 ]
}

@test "no drift is reported when the content did not change between Stops" {
	# The correctness half, and the one that matches the field evidence: two
	# evaluations of identical bytes scored 0.88 and 0.64 ten seconds apart,
	# and echo called that a regression. With the stub stepping 0.80 -> 0.60,
	# a second evaluation would emit one; a skip emits nothing.
	_dirty_the_file "EDITED ONCE"
	_run_hook "sess-1"
	[ "$(_drift_events)" -eq 0 ] || return 1

	_run_hook "sess-2"
	[ "$(_drift_events)" -eq 0 ]
}

@test "a skipped re-run leaves the baseline score untouched" {
	# The baseline random-walked in the field -- 0.78, 0.65, 0.72 on a file
	# that never moved -- because every run overwrote it before comparing.
	# A run that evaluates nothing must not move the reference point.
	_dirty_the_file "EDITED ONCE"
	_run_hook "sess-1"
	[ -f "$BASELINE_FILE" ] || return 1
	local first
	first=$(jq -r '.score' "$BASELINE_FILE")
	[ "$first" = "0.80" ] || return 1

	_run_hook "sess-2"
	[ "$(jq -r '.score' "$BASELINE_FILE")" = "0.80" ]
}

@test "the baseline records the content hash it was scored from" {
	# Without this field the hook has no way to answer "have I already scored
	# these bytes", which is the root cause of all three symptoms above.
	_dirty_the_file "EDITED ONCE"
	_run_hook "sess-1"
	[ -f "$BASELINE_FILE" ] || return 1

	local recorded actual
	recorded=$(jq -r '.content_sha256 // empty' "$BASELINE_FILE")
	actual=$(shasum -a 256 "${REPO}/agents/reviewer.md" | cut -d' ' -f1)
	[ -n "$recorded" ] || return 1
	[ "$recorded" = "$actual" ]
}

@test "a further edit is evaluated again and does report drift" {
	# The inverse, so the fix cannot become "never evaluate twice". Real
	# content changes are exactly what echo exists to score.
	_dirty_the_file "EDITED ONCE"
	_run_hook "sess-1"
	[ "$(_claude_calls)" -eq 1 ] || return 1

	_dirty_the_file "EDITED A SECOND TIME"
	_run_hook "sess-2"
	[ "$(_claude_calls)" -eq 2 ] || return 1
	# 0.80 -> 0.60 crosses the 0.05 threshold downward.
	[ "$(_drift_events)" -eq 1 ] || return 1
	grep -q '"event_type":"echo\.regression\.detected"' "$ONLOOKER_EVENTS_LOG"
}

@test "a baseline written before content hashing existed is re-evaluated once" {
	# Backward compatibility. Baselines on disk today carry no content_sha256;
	# treating a missing hash as "matches" would freeze echo permanently.
	_dirty_the_file "EDITED ONCE"
	mkdir -p "$BASELINE_DIR"
	jq -n --arg p "agents/reviewer.md" --arg t "$TEST_ID" \
		'{path: $p, test_id: $t, score: 0.5, recorded_at: "2026-09-01T00:00:00Z"}' \
		> "$BASELINE_FILE"

	_run_hook "sess-1"
	[ "$(_claude_calls)" -eq 1 ] || return 1
	[ -n "$(jq -r '.content_sha256 // empty' "$BASELINE_FILE")" ]
}

@test "an unchanged file starts no suite at all" {
	# A suite that evaluates nothing is not a suite. Emitting started/complete
	# around zero work is what made the repeat runs look like real activity in
	# the event log.
	_dirty_the_file "EDITED ONCE"
	_run_hook "sess-1"
	local after_first
	after_first=$(grep -c '"event_type":"echo\.suite\.started"' "$ONLOOKER_EVENTS_LOG")
	[ "$after_first" -eq 1 ] || return 1

	_run_hook "sess-2"
	[ "$(grep -c '"event_type":"echo\.suite\.started"' "$ONLOOKER_EVENTS_LOG")" -eq 1 ]
}

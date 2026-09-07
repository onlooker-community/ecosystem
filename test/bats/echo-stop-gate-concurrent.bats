#!/usr/bin/env bats

# Echo's baseline read-modify-write races across concurrent sessions
# (ecosystem-449.46).
#
# The read of SCORE_BEFORE and the write of the new baseline both sit
# DOWNSTREAM of a 26-60s judge call, with no lock and no compare-and-swap. Two
# sessions that evaluate the same watched file in overlapping windows both
# clear the pre-judge content filter -- neither has recorded the new hash yet --
# and whichever finishes second reads the other's just-written score as its own
# baseline. It then diffs sample-vs-sample instead of edit-vs-baseline, and one
# user edit emits both an improvement AND a regression.
#
# Observed in the field on one edit: 0.64 -> 0.86 -> 0.77, where 0.86 and 0.77
# are two independent judge samples of IDENTICAL bytes and their 0.09 spread
# clears the 0.05 drift_threshold.
#
# A lock does not fix this, which is why these tests assert on the verdict
# count rather than on serialization: serializing the read-modify-write still
# leaves the second session reading a baseline recorded from the same bytes it
# just judged. The fix has to compare CONTENT IDENTITY after the judge returns.
#
# The stub below stands in for judge noise. It orders the two callers with an
# atomic mkdir and staggers their sleeps, so the interleaving under test is
# deterministic: the first judge returns and writes while the second is still
# in its call.

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

	# A baseline scored from the COMMITTED bytes. Both sessions must see the
	# edited file as changed, so drift is computed rather than skipped.
	mkdir -p "$BASELINE_DIR"
	COMMITTED_SHA=$(echo_content_sha256 "${REPO}/agents/reviewer.md")
	jq -n --arg path "agents/reviewer.md" --arg test_id "$TEST_ID" \
		--arg sha "$COMMITTED_SHA" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{path: $path, test_id: $test_id, score: 0.64,
		  content_sha256: $sha, recorded_at: $ts}' > "$BASELINE_FILE"

	CLAUDE_MARKER="${BATS_TEST_TMPDIR}/claude-calls"
	ORDER_DIR="${BATS_TEST_TMPDIR}/order"
	mkdir -p "$ORDER_DIR"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"

	# mkdir is atomic, so exactly one caller wins "first" no matter how the two
	# hooks interleave. First returns quickly and writes its baseline; second
	# is still inside its judge when that happens, then wakes to find a
	# baseline recorded from the very bytes it just scored. Scores replay the
	# field trace: 0.64 -> 0.86 (+0.22, improvement) -> 0.77 (-0.09, regression).
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf 'call\n' >> "${CLAUDE_MARKER}"
if mkdir "${ORDER_DIR}/first" 2>/dev/null; then
	sleep 1
	printf '{"score":0.86,"passed":true,"confidence":0.9,"feedback":"stub"}'
else
	sleep 3
	printf '{"score":0.77,"passed":true,"confidence":0.9,"feedback":"stub"}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_dirty_the_file() {
	printf '# Agent\n\n%s\n' "$1" > "${REPO}/agents/reviewer.md"
}

# Backgrounded, so both hooks are inside their judge at the same time. `run`
# cannot be used here -- it is synchronous.
_run_hook_bg() {
	local input
	input=$(jq -n --arg cwd "$REPO" --arg sid "$1" '{cwd: $cwd, session_id: $sid}')
	printf '%s' "$input" | "$HOOK" >/dev/null 2>&1 &
}

_claude_calls() {
	[ -f "$CLAUDE_MARKER" ] || { printf '0'; return 0; }
	wc -l < "$CLAUDE_MARKER" | tr -d ' '
}

_drift_events() {
	[ -f "$ONLOOKER_EVENTS_LOG" ] || { printf '0'; return 0; }
	local n
	n=$(grep -c '"event_type":"echo\.\(regression\|improvement\)\.detected"' \
		"$ONLOOKER_EVENTS_LOG" 2>/dev/null) || n=0
	printf '%s' "$n"
}

_baseline_score() {
	[ -f "$BASELINE_FILE" ] || { printf 'none'; return 0; }
	jq -r '.score' "$BASELINE_FILE"
}

@test "one edit produces exactly one verdict across two concurrent sessions" {
	# The correctness half. Two sessions, one edit, two judge samples of the
	# same bytes -- but only one of them is a verdict about the edit. The other
	# is a verdict about judge noise and must not be emitted.
	_dirty_the_file "EDITED ONCE"
	_run_hook_bg "sess-a"
	_run_hook_bg "sess-b"
	wait

	# Both sessions must genuinely have judged; if the pre-judge filter skipped
	# one, this test would pass without exercising the race at all.
	[ "$(_claude_calls)" -eq 2 ] || return 1

	[ "$(_drift_events)" -eq 1 ]
}

@test "the losing session does not overwrite the baseline with its own sample" {
	# The persistence half, and why this is P1 rather than cosmetic: the
	# corrupted score becomes the baseline every future run compares against,
	# so one race poisons the file's whole subsequent history.
	_dirty_the_file "EDITED ONCE"
	_run_hook_bg "sess-a"
	_run_hook_bg "sess-b"
	wait

	[ "$(_claude_calls)" -eq 2 ] || return 1

	# 0.86 is the first judge's score for these bytes. 0.77 is the second
	# sample of the SAME bytes and must not replace it.
	[ "$(_baseline_score)" = "0.86" ]
}

@test "a baseline recorded from different content still reports drift" {
	# The guard on the fix: suppression must key on content identity, not on
	# "a baseline exists". A single session evaluating a genuine edit against a
	# baseline scored from other bytes must still emit its verdict.
	_dirty_the_file "EDITED ONCE"
	_run_hook_bg "sess-solo"
	wait

	[ "$(_claude_calls)" -eq 1 ] || return 1

	# 0.64 -> 0.86 is +0.22, well past the 0.05 threshold.
	[ "$(_drift_events)" -eq 1 ]
}

@test "a baseline written before content hashing existed still evaluates" {
	# Pre-449.40 records carry no content_sha256. Treating a missing hash as a
	# match would freeze echo on every file it had already seen, so the
	# duplicate check must not fire on an absent stamp.
	jq -n --arg path "agents/reviewer.md" --arg test_id "$TEST_ID" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{path: $path, test_id: $test_id, score: 0.64, recorded_at: $ts}' \
		> "$BASELINE_FILE"

	_dirty_the_file "EDITED ONCE"
	_run_hook_bg "sess-legacy"
	wait

	[ "$(_claude_calls)" -eq 1 ] || return 1
	[ "$(_drift_events)" -eq 1 ]
}

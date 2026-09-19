#!/usr/bin/env bats

# Exercises the SessionEnd hook end-to-end against an isolated $ONLOOKER_DIR.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/bursar-session-end.sh"
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	SID="bats-end-001"
	PK="projendabcd12"
}

_breadcrumb() {
	local dir="${ONLOOKER_DIR}/bursar/sessions"
	mkdir -p "$dir"
	jq -n --arg pk "$PK" '{project_key:$pk, cwd:"/tmp", started_at:"x"}' > "${dir}/${SID}.json"
}

_seed_governor_event() {
	# A minimal but well-formed governor.session.complete envelope line.
	jq -nc --arg sid "$SID" \
		'{event_type:"governor.session.complete", plugin:"governor", session_id:"outer",
		  payload:{session_id:$sid, total_cost_usd:0.42, total_tokens:42000, total_api_calls:12,
		           budget_usd:1.0, under_budget:true, duration_ms:0, calls_blocked:0,
		           calls_warned:0, ledger_poisoned:false}}' >> "$ONLOOKER_EVENTS_LOG"
}

_ledger_path() { printf '%s/bursar/projects/%s/sessions.jsonl' "$ONLOOKER_DIR" "$PK"; }

_run_hook() {
	printf '%s' "{\"session_id\":\"$SID\"}" > "${BATS_TEST_TMPDIR}/in.json"
	run bash "$HOOK" < "${BATS_TEST_TMPDIR}/in.json"
}

@test "records a session's spend from governor.session.complete" {
	_breadcrumb
	_seed_governor_event
	_run_hook
	[ "$status" -eq 0 ]

	local path
	path=$(_ledger_path)
	[ -f "$path" ]
	[ "$(wc -l < "$path")" -eq 1 ]
	[ "$(jq -r '.cost_usd' "$path")" = "0.42" ]
	[ "$(jq -r '.tokens' "$path")" = "42000" ]
	[ "$(jq -r '.api_calls' "$path")" = "12" ]
	[ "$(jq -r '.governor_present' "$path")" = "true" ]
	[ "$(jq -r '.session_id' "$path")" = "$SID" ]
}

@test "removes the breadcrumb after recording" {
	_breadcrumb
	_seed_governor_event
	_run_hook
	[ ! -f "${ONLOOKER_DIR}/bursar/sessions/${SID}.json" ]
}

@test "degrades to governor_present:false when no governor event exists" {
	_breadcrumb
	# no governor.session.complete seeded
	_run_hook
	[ "$status" -eq 0 ]

	local path
	path=$(_ledger_path)
	[ -f "$path" ]
	[ "$(jq -r '.governor_present' "$path")" = "false" ]
	[ "$(jq -r 'has("cost_usd")' "$path")" = "false" ]
}

@test "is idempotent across a repeated SessionEnd" {
	_breadcrumb
	_seed_governor_event
	_run_hook
	# Breadcrumb is gone now; re-create it to simulate a second SessionEnd.
	_breadcrumb
	_run_hook
	[ "$(wc -l < "$(_ledger_path)")" -eq 1 ]
}

@test "keeps the breadcrumb and emits nothing when the ledger write fails" {
	_breadcrumb
	_seed_governor_event
	# Force bursar_ledger_record to fail: a file where the projects dir must go,
	# so its `mkdir -p` cannot create the project directory.
	mkdir -p "${ONLOOKER_DIR}/bursar"
	printf 'x' > "${ONLOOKER_DIR}/bursar/projects"
	_run_hook
	[ "$status" -eq 0 ]
	# Breadcrumb retained so the attribution survives for a later attempt.
	[ -f "${ONLOOKER_DIR}/bursar/sessions/${SID}.json" ]
	# No false "recorded" event.
	run grep -c '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG"
	[ "$output" -eq 0 ]
}

@test "emits bursar.session.recorded" {
	_breadcrumb
	_seed_governor_event
	_run_hook
	run grep -c '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

# ecosystem-449.29. Record how the hook reads the event log.
#
# A wall-clock budget would be the obvious assertion and the wrong one: flaky on
# a loaded machine, and the cost here is not time but whether the read is
# BOUNDED. What costs is bytes off disk, so this records every `tail` against
# the log and the -n it asked for. A read with no -n, or one that grows with the
# log, is the defect. Exact under any load.
#
# An earlier version of this helper counted greps instead and measured nothing
# useful: the hook greps an in-memory slice, so the count was the same whether
# it had read 2,000 lines or 182,000.
_record_log_reads() {
	local real_tail
	real_tail=$(command -v tail)
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	export TAIL_LOG_FILE="${BATS_TEST_TMPDIR}/tail-calls"
	: > "$TAIL_LOG_FILE"
	cat > "${STUB_BIN}/tail" <<STUB
#!/usr/bin/env bash
# Only reads of the event log are interesting.
case "\$*" in
  *onlooker-events.jsonl*)
    n=unbounded
    prev=""
    for a in "\$@"; do
      [ "\$prev" = "-n" ] && n="\$a"
      prev="\$a"
    done
    printf '%s\n' "\$n" >> "${TAIL_LOG_FILE}"
    ;;
esac
exec "${real_tail}" "\$@"
STUB
	chmod +x "${STUB_BIN}/tail"
	export PATH="${STUB_BIN}:${PATH}"
}

# Pad the log so a whole-file scan would be visibly different from a slice.
_pad_log() {
	local n="$1" i
	for ((i = 0; i < n; i++)); do
		printf '{"event_type":"tool.file.read","plugin":"onlooker","session_id":"other","payload":{"path":"x"}}\n'
	done >> "$ONLOOKER_EVENTS_LOG"
}

@test "the event log is never read past the deep bound" {
	# THE DEFECT. The near slice missed and the hook then scanned the ENTIRE log
	# for an event that could not exist. Measured against this machine's
	# 181,916-line log: 712-742ms per SessionEnd, 704ms of it grep, reading
	# 2,843 stale governor events only to filter them all out by session_id.
	# Not a corner case -- governor has been disabled since the 2026-09-07
	# rollback, so the near slice missed on every single session.
	#
	# Asserted with a SENTINEL rather than by watching how the file is read. The
	# first version of this test stubbed `tail` and checked its -n, and a mutant
	# restoring the old `_latest_governor_spend < "$LOG"` sailed straight past
	# it: redirection never calls tail, so the stub saw nothing. A sentinel is
	# indifferent to mechanism -- the only matching event sits at the very TOP of
	# a log padded past the bound, so a bounded reader cannot see it and any
	# unbounded reader can.
	#
	# It also pins the accepted tradeoff honestly: an event older than the bound
	# is treated as absent. That costs one session's cost attribution, against
	# ~700ms on every session forever.
	_breadcrumb
	_seed_governor_event      # the sentinel: first line of the log
	_pad_log 21000           # push it beyond _BURSAR_SPEND_DEEP_LINES (20000)

	_run_hook
	[ "$status" -eq 0 ] || return 1
	grep '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG" \
		| tail -1 | jq -e '.payload.governor_present == false' >/dev/null
}

@test "a session with no governor event anywhere is still recorded" {
	# Bounding the reads must not cost correctness: when there is genuinely no
	# spend to find, the session is still recorded with cost unknown, which is
	# the contract the hook already documents.
	_breadcrumb
	_pad_log 3000
	_run_hook
	[ "$status" -eq 0 ] || return 1
	grep '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG" \
		| tail -1 | jq -e '.payload.governor_present == false' >/dev/null
}

@test "an event pushed past the near slice is still found" {
	# The reason a second look exists at all. A long session can push its own
	# governor event beyond the near slice -- measured max gap 17,433 lines
	# against a 2,000-line near slice.
	#
	# This is also the test that killed a cleverer design. An earlier attempt
	# skipped the deep look whenever the near slice held no governor events for
	# any session, on the theory that governor must be off. It fails here for
	# the same reason the lookup did: the only governor event is beyond the near
	# slice, so the presence check misses too and the spend is lost. The deep
	# look is now unconditional and merely bounded.
	_breadcrumb
	_seed_governor_event
	_pad_log 2500

	_run_hook
	[ "$status" -eq 0 ] || return 1
	grep '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG" \
		| tail -1 | jq -e '.payload.governor_present == true and .payload.cost_usd == 0.42' >/dev/null
}

@test "the deep look is bounded too, even when it runs" {
	# The miss path is the one that used to read everything, so it is the one
	# worth pinning: reaching deeper must still not mean reading the whole file.
	_breadcrumb
	_seed_governor_event
	_pad_log 2500
	_record_log_reads

	_run_hook
	[ "$status" -eq 0 ] || return 1
	! grep -q 'unbounded' "$TAIL_LOG_FILE" || return 1
	local n
	while IFS= read -r n; do
		[ "$n" -le 20000 ] || return 1
	done < "$TAIL_LOG_FILE"
}

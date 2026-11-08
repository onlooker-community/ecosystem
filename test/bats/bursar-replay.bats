#!/usr/bin/env bats

# Exercises the stranded-breadcrumb replay against an isolated $ONLOOKER_DIR.
#
# A breadcrumb outlives its session whenever SessionEnd fails to record it: a
# ledger lock contended past the 1s timeout, a write that failed, or a hook the
# CLI killed at its 1.5s SessionEnd deadline. Nothing read those files again,
# so 473 of them piled up on one machine, each a session missing from its
# project's ledger (ONL-34).

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	REPLAY="${PLUGIN_ROOT}/scripts/bursar-replay.sh"
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	BC_DIR="${ONLOOKER_DIR}/bursar/sessions"
	mkdir -p "$BC_DIR"
	PK="projreplay012"
}

_ledger_path() { printf '%s/bursar/projects/%s/sessions.jsonl' "$ONLOOKER_DIR" "${1:-$PK}"; }

# _breadcrumb <sid> <days_old> [project_key]
# Written the way SessionStart writes one, then aged: replay keys on mtime.
_breadcrumb() {
	local sid="$1" days="$2" pk="${3-$PK}" started
	started=$(relative_iso_days_ago "$days")
	jq -n --arg sid "$sid" --arg pk "$pk" --arg ts "$started" \
		'{session_id: $sid, project_key: $pk, cwd: "/tmp", started_at: $ts}' \
		>"${BC_DIR}/${sid}.json"
	touch -d "$started" "${BC_DIR}/${sid}.json"
}

_seed_governor_event() {
	local sid="$1" ts="$2"
	jq -nc --arg sid "$sid" --arg ts "$ts" \
		'{event_type:"governor.session.complete", plugin:"governor", session_id:$sid, timestamp:$ts,
		  payload:{session_id:$sid, total_cost_usd:0.42, total_tokens:42000, total_api_calls:12,
		           budget_usd:1.0, under_budget:true, duration_ms:0, calls_blocked:0,
		           calls_warned:0, ledger_poisoned:false}}' >>"$ONLOOKER_EVENTS_LOG"
}

_epoch_of() { jq -rn --arg ts "$1" '$ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601'; }

@test "records a stranded breadcrumb into its project's ledger and drops it" {
	_breadcrumb "sess-stranded" 3
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	[ ! -f "${BC_DIR}/sess-stranded.json" ] || return 1
	[ "$(jq -r 'select(.session_id == "sess-stranded") | .project_key' "$(_ledger_path)")" = "$PK" ] || return 1
	grep '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e --arg pk "$PK" '.payload.session_id == "sess-stranded" and .payload.project_key == $pk' >/dev/null
}

@test "dates a session without governor spend to its start, not to the replay" {
	_breadcrumb "sess-nogov" 3
	local started
	started=$(jq -r '.started_at' "${BC_DIR}/sess-nogov.json")
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	local rec
	rec=$(jq -c 'select(.session_id == "sess-nogov")' "$(_ledger_path)")
	[ "$(jq -r '.governor_present' <<<"$rec")" = "false" ] || return 1
	[ "$(jq -r 'has("cost_usd")' <<<"$rec")" = "false" ] || return 1
	[ "$(jq -r '.ts' <<<"$rec")" = "$started" ] || return 1
	[ "$(jq -r '.ts_epoch' <<<"$rec")" = "$(_epoch_of "$started")" ]
}

@test "carries governor spend, timed to governor's event, when the log has it" {
	_breadcrumb "sess-gov" 3
	local gov_ts
	gov_ts="$(relative_iso_days_ago 2 | sed 's/Z$/.692Z/')"
	_seed_governor_event "sess-other" "$gov_ts"
	_seed_governor_event "sess-gov" "$gov_ts"
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	local rec
	rec=$(jq -c 'select(.session_id == "sess-gov")' "$(_ledger_path)")
	[ "$(jq -r '.governor_present' <<<"$rec")" = "true" ] || return 1
	[ "$(jq -r '.cost_usd' <<<"$rec")" = "0.42" ] || return 1
	[ "$(jq -r '.tokens' <<<"$rec")" = "42000" ] || return 1
	[ "$(jq -r '.api_calls' <<<"$rec")" = "12" ] || return 1
	[ "$(jq -r '.ts_epoch' <<<"$rec")" = "$(_epoch_of "$gov_ts")" ]
}

@test "leaves a breadcrumb under a day old alone: its session may still be running" {
	_breadcrumb "sess-live" 0
	# 23 hours, not seconds: a seconds-old file passes any age check at all.
	touch -d "$(python3 -c 'import datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=23)).strftime("%Y-%m-%dT%H:%M:%SZ"))')" \
		"${BC_DIR}/sess-live.json"
	_breadcrumb "sess-stranded" 3
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	[ -f "${BC_DIR}/sess-live.json" ] || return 1
	[ "$(jq -c 'select(.session_id == "sess-live")' "$(_ledger_path)")" = "" ]
}

@test "drops the breadcrumb of a session already recorded, keeping the real record" {
	_breadcrumb "sess-done" 3
	mkdir -p "$(dirname "$(_ledger_path)")"
	jq -nc --arg pk "$PK" \
		'{ts:"real", ts_epoch:1, session_id:"sess-done", project_key:$pk, governor_present:false}' \
		>"$(_ledger_path)"
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	[ ! -f "${BC_DIR}/sess-done.json" ] || return 1
	[ "$(wc -l <"$(_ledger_path)")" -eq 1 ] || return 1
	[ "$(jq -r '.ts' "$(_ledger_path)")" = "real" ] || return 1
	! grep -q '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG"
}

@test "discards a breadcrumb that names no project, and says so in the log" {
	_breadcrumb "sess-nokey" 3 ""
	printf 'not json' >"${BC_DIR}/sess-garbage.json"
	touch -d "$(relative_iso_days_ago 3)" "${BC_DIR}/sess-garbage.json"
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	[ ! -f "${BC_DIR}/sess-nokey.json" ] || return 1
	[ ! -f "${BC_DIR}/sess-garbage.json" ] || return 1
	grep -q 'discarded=2' "${ONLOOKER_DIR}/bursar/replay.log"
}

@test "keeps the breadcrumb for the next run when the ledger write fails" {
	_breadcrumb "sess-unwritable" 3
	# A file where the project's ledger directory belongs makes mkdir fail.
	mkdir -p "${ONLOOKER_DIR}/bursar/projects"
	: >"${ONLOOKER_DIR}/bursar/projects/${PK}"
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	[ -f "${BC_DIR}/sess-unwritable.json" ] || return 1
	grep -q 'failed=1' "${ONLOOKER_DIR}/bursar/replay.log"
}

@test "falls back to the file name for a breadcrumb written before it carried session_id" {
	jq -n --arg pk "$PK" '{project_key: $pk, cwd: "/tmp", started_at: "2026-08-30T15:42:48Z"}' \
		>"${BC_DIR}/sess-legacy.json"
	touch -d "$(relative_iso_days_ago 3)" "${BC_DIR}/sess-legacy.json"
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	[ "$(jq -r 'select(.session_id == "sess-legacy") | .ts' "$(_ledger_path)")" = "2026-08-30T15:42:48Z" ]
}

@test "does nothing while another replay holds the lock" {
	_breadcrumb "sess-stranded" 3
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
	lock_acquire "${ONLOOKER_DIR}/bursar/replay.lock" 1
	run bash "$REPLAY"
	lock_release "${ONLOOKER_DIR}/bursar/replay.lock"
	[ "$status" -eq 0 ] || return 1

	[ -f "${BC_DIR}/sess-stranded.json" ]
}

@test "SessionStart writes session_id into its breadcrumb and launches the replay" {
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	local repo="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "$repo"
	git init -q "$repo" 2>/dev/null
	git -C "$repo" remote add origin https://example.com/onlooker/bursar-replay.git 2>/dev/null

	_breadcrumb "sess-stranded" 3
	jq -cn --arg cwd "$repo" '{session_id: "sess-now", cwd: $cwd, source: "startup"}' \
		>"${BATS_TEST_TMPDIR}/in.json"
	run bash "${PLUGIN_ROOT}/scripts/hooks/bursar-session-start.sh" <"${BATS_TEST_TMPDIR}/in.json"
	[ "$status" -eq 0 ] || return 1
	[ "$(jq -r '.session_id' "${BC_DIR}/sess-now.json")" = "sess-now" ] || return 1

	await_events "bursar.session.recorded" 1 || return 1
	grep '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.session_id == "sess-stranded"' >/dev/null || return 1
	[ -f "${BC_DIR}/sess-now.json" ]
}

@test "dates a breadcrumb with no usable started_at to when SessionStart wrote it" {
	_breadcrumb "sess-nostart" 3
	jq '.started_at = "x"' "${BC_DIR}/sess-nostart.json" >"${BATS_TEST_TMPDIR}/bc.json"
	mv "${BATS_TEST_TMPDIR}/bc.json" "${BC_DIR}/sess-nostart.json"
	local written
	written=$(relative_iso_days_ago 3)
	touch -d "$written" "${BC_DIR}/sess-nostart.json"
	run bash "$REPLAY"
	[ "$status" -eq 0 ] || return 1

	[ "$(jq -r 'select(.session_id == "sess-nostart") | .ts_epoch' "$(_ledger_path)")" = "$(_epoch_of "$written")" ]
}

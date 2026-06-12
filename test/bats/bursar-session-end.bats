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

_enable() {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"enabled":true}}' > "${HOME}/.claude/settings.json"
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
	_enable
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
	_enable
	_breadcrumb
	_seed_governor_event
	_run_hook
	[ ! -f "${ONLOOKER_DIR}/bursar/sessions/${SID}.json" ]
}

@test "degrades to governor_present:false when no governor event exists" {
	_enable
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
	_enable
	_breadcrumb
	_seed_governor_event
	_run_hook
	# Breadcrumb is gone now; re-create it to simulate a second SessionEnd.
	_breadcrumb
	_run_hook
	[ "$(wc -l < "$(_ledger_path)")" -eq 1 ]
}

@test "writes nothing when bursar is disabled" {
	# bursar disabled (no settings written)
	_breadcrumb
	_seed_governor_event
	_run_hook
	[ "$status" -eq 0 ]
	[ ! -d "${ONLOOKER_DIR}/bursar/projects" ]
}

@test "emits bursar.session.recorded" {
	_enable
	_breadcrumb
	_seed_governor_event
	_run_hook
	run grep -c '"event_type":"bursar.session.recorded"' "$ONLOOKER_EVENTS_LOG"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

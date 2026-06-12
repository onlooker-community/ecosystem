#!/usr/bin/env bats

# Exercises the SessionStart hook end-to-end against an isolated $ONLOOKER_DIR.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/bursar-session-start.sh"
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/bursar-project-key.sh"

	# A real git repo so a project key resolves.
	REPO="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "$REPO"
	git init -q "$REPO" 2>/dev/null
	git -C "$REPO" remote add origin https://example.com/onlooker/bursar-test.git 2>/dev/null
	KEY=$(bursar_project_key "$REPO")

	SID="bats-start-001"
}

_enable() {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"enabled":true}}' > "${HOME}/.claude/settings.json"
}

_seed_ledger() {
	# One recent recorded session with cost.
	local dir="${ONLOOKER_DIR}/bursar/projects/${KEY}"
	mkdir -p "$dir"
	local now
	now=$(date +%s)
	jq -nc --arg pk "$KEY" --argjson te "$now" \
		'{ts:"x", ts_epoch:$te, session_id:"older", project_key:$pk,
		  governor_present:true, cost_usd:0.42, tokens:42000, api_calls:12}' \
		> "${dir}/sessions.jsonl"
}

_run_hook() {
	printf '%s' "{\"session_id\":\"$SID\",\"cwd\":\"$REPO\",\"source\":\"startup\"}" \
		> "${BATS_TEST_TMPDIR}/in.json"
	run bash "$HOOK" < "${BATS_TEST_TMPDIR}/in.json"
}

@test "produces no output when bursar is disabled" {
	_run_hook
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "writes a breadcrumb carrying the project key" {
	_enable
	_run_hook
	[ "$status" -eq 0 ]
	local bc="${ONLOOKER_DIR}/bursar/sessions/${SID}.json"
	[ -f "$bc" ]
	[ "$(jq -r '.project_key' "$bc")" = "$KEY" ]
}

@test "surfaces no additionalContext when the window is empty" {
	_enable
	_run_hook
	[ "$status" -eq 0 ]
	[[ "$output" != *"hookSpecificOutput"* ]]
}

@test "emits bursar.rollup.skipped when there is no data" {
	_enable
	_run_hook
	run grep -c '"event_type":"bursar.rollup.skipped"' "$ONLOOKER_EVENTS_LOG"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

@test "surfaces the burned total as SessionStart additionalContext" {
	_enable
	_seed_ledger
	_run_hook
	[ "$status" -eq 0 ]
	[[ "$output" == *"hookSpecificOutput"* ]]
	[[ "$output" == *"SessionStart"* ]]
	[[ "$output" == *"burned \$0.42"* ]]
}

@test "emits bursar.rollup.surfaced when data exists" {
	_enable
	_seed_ledger
	_run_hook
	run grep -c '"event_type":"bursar.rollup.surfaced"' "$ONLOOKER_EVENTS_LOG"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
}

@test "stays silent at the surface step but still records the breadcrumb when surfacing is disabled" {
	mkdir -p "${HOME}/.claude"
	printf '%s\n' '{"bursar":{"enabled":true,"surface_at_session_start":false}}' \
		> "${HOME}/.claude/settings.json"
	_seed_ledger
	_run_hook
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ -f "${ONLOOKER_DIR}/bursar/sessions/${SID}.json" ]
}

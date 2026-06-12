#!/usr/bin/env bats

# Validates that bursar.* events pass @onlooker-community/schema validation.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/bursar"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/bursar-events.sh"

	export CLAUDE_SESSION_ID="bats-bursar-session-$$"
	PK="proj0123abcd"
	SID="bats-bursar-sid-000"
}

_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

@test "bursar.session.recorded with governor present validates" {
	local p
	p=$(jq -n --arg pk "$PK" --arg sid "$SID" \
		'{project_key:$pk, session_id:$sid, governor_present:true,
		  cost_usd:0.42, tokens:42000, api_calls:12, model:"claude-opus-4-8"}')
	bursar_emit_event "bursar.session.recorded" "$p" "$SID"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "bursar.session.recorded with governor absent validates" {
	local p
	p=$(jq -n --arg pk "$PK" --arg sid "$SID" \
		'{project_key:$pk, session_id:$sid, governor_present:false}')
	bursar_emit_event "bursar.session.recorded" "$p" "$SID"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "bursar.rollup.surfaced validates" {
	local p
	p=$(jq -n --arg pk "$PK" \
		'{project_key:$pk, window:"rolling_7d", total_cost_usd:3.17,
		  session_count:8, total_tokens:310000, sessions_with_cost:7,
		  window_start:"2026-06-05T00:00:00Z"}')
	bursar_emit_event "bursar.rollup.surfaced" "$p" "$SID"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "bursar.rollup.skipped validates" {
	local p
	p=$(jq -n --arg pk "$PK" '{reason:"no_data", project_key:$pk}')
	bursar_emit_event "bursar.rollup.skipped" "$p" "$SID"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "bursar_emit_event returns nonzero for an unknown event type" {
	run bursar_emit_event "bursar.no_such_event" '{"project_key":"x"}' "$SID"
	[ "$status" -ne 0 ]
}

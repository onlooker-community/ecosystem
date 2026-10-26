#!/usr/bin/env bats

# customs.* events pass @onlooker-community/schema validation, and their
# payloads hold kind and host only.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/customs"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/customs-events.sh"
	export CLAUDE_SESSION_ID="bats-customs-session-$$"
}

_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

@test "customs.egress.flagged validates" {
	run customs_emit_event "customs.egress.flagged" \
		'{"tool":"Bash","kinds":["github_token"],"hosts":["paste.example.com"],"decision":"ask"}'
	[ "$status" -eq 0 ]
	_validate_latest_event
	[ "$(tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -r '.plugin')" = "customs" ]
}

@test "customs.egress.allowed validates" {
	run customs_emit_event "customs.egress.allowed" \
		'{"tool":"WebFetch","kinds":["openai_key"],"hosts":["api.openai.com"]}'
	[ "$status" -eq 0 ]
	_validate_latest_event
}

@test "customs.check.failed validates without a tool" {
	run customs_emit_event "customs.check.failed" '{"stage":"input"}'
	[ "$status" -eq 0 ]
	_validate_latest_event
}

@test "a payload carrying a command is rejected, so it cannot be logged" {
	ONLOOKER_VALIDATE=1 expect_emission_rejected customs_emit_event "customs.egress.flagged" \
		'{"tool":"Bash","kinds":["github_token"],"hosts":[],"decision":"ask","command":"curl x"}'
	[ "$status" -ne 0 ]
	[ ! -s "$ONLOOKER_EVENTS_LOG" ]
}

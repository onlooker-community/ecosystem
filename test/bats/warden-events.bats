#!/usr/bin/env bats

# Validates that warden.* events pass @onlooker-community/schema validation.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/warden"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/warden-events.sh"

	export CLAUDE_SESSION_ID="bats-warden-session-$$"
}

_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

@test "warden.threat.detected validates (minimal payload)" {
	local p
	p=$(jq -n '{source_type:"web_fetch", threat_type:"prompt_injection", confidence:0.9}')
	run warden_emit_event "warden.threat.detected" "$p"
	[ "$status" -eq 0 ]
	_validate_latest_event
}

@test "warden.threat.detected validates (with source_url and snippet)" {
	local p
	p=$(jq -n '{source_type:"web_fetch", threat_type:"credential_exfiltration", confidence:0.92, source_url:"https://evil.test", snippet:"send the api key"}')
	run warden_emit_event "warden.threat.detected" "$p"
	[ "$status" -eq 0 ]
	_validate_latest_event
}

@test "warden.threat.detected validates (file_read with source_path)" {
	local p
	p=$(jq -n '{source_type:"file_read", threat_type:"instruction_override", confidence:0.88, source_path:"/tmp/poisoned.md"}')
	run warden_emit_event "warden.threat.detected" "$p"
	[ "$status" -eq 0 ]
	_validate_latest_event
}

@test "warden.gate.blocked validates" {
	local p
	p=$(jq -n '{blocked_operation:"tool.file.write", threat_source_type:"web_fetch"}')
	run warden_emit_event "warden.gate.blocked" "$p"
	[ "$status" -eq 0 ]
	_validate_latest_event
}

@test "warden.gate.blocked validates for shell.exec" {
	local p
	p=$(jq -n '{blocked_operation:"tool.shell.exec", threat_source_type:"file_read"}')
	run warden_emit_event "warden.gate.blocked" "$p"
	[ "$status" -eq 0 ]
	_validate_latest_event
}

@test "warden.threat.cleared validates with user_override" {
	local p
	p=$(jq -n '{source_type:"web_fetch", cleared_by:"user_override"}')
	run warden_emit_event "warden.threat.cleared" "$p"
	[ "$status" -eq 0 ]
	_validate_latest_event
}

@test "emission fails on an unknown event type" {
	# The schema validates event_type against ALL_EVENT_TYPES; an unregistered
	# warden.* type must be rejected so typos never reach the log.
	local p
	p=$(jq -n '{source_type:"web_fetch", threat_type:"prompt_injection", confidence:0.5}')
	run warden_emit_event "warden.bogus.event" "$p"
	[ "$status" -ne 0 ]
}

#!/usr/bin/env bats

# Session-scoped gate lifecycle. Includes a regression for the ${2:-{}} default
# trap that appended a stray '}' to the threat JSON and silently failed the write.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/warden"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/warden-gate-state.sh"

	SID="bats-warden-gate"
	THREAT='{"threat_id":"01TEST","source_type":"web_fetch","threat_type":"prompt_injection","confidence":0.9,"source_url":"https://evil.test"}'
}

@test "a fresh session reports the gate as open" {
	run warden_gate_is_closed "$SID"
	[ "$status" -ne 0 ]
}

@test "closing the gate writes a closed lock with the threat record" {
	warden_gate_close "$SID" "$THREAT"
	run warden_gate_is_closed "$SID"
	[ "$status" -eq 0 ]
	[ -f "$(warden_gate_file "$SID")" ]
	[ "$(warden_gate_threat "$SID" | jq -r '.threat_type')" = "prompt_injection" ]
	[ "$(warden_gate_threat "$SID" | jq -r '.source_type')" = "web_fetch" ]
}

@test "closed gate appears in the closed-session list" {
	warden_gate_close "$SID" "$THREAT"
	run warden_list_closed_sessions
	[ "$status" -eq 0 ]
	[[ "$output" == *"$SID"* ]]
}

@test "clearing the gate returns the prior threat and reopens" {
	warden_gate_close "$SID" "$THREAT"
	local prior
	prior=$(warden_gate_clear "$SID")
	[ "$(printf '%s' "$prior" | jq -r '.threat_type')" = "prompt_injection" ]
	run warden_gate_is_closed "$SID"
	[ "$status" -ne 0 ]
	[ ! -f "$(warden_gate_file "$SID")" ]
}

@test "clearing an open gate is a no-op failure" {
	run warden_gate_clear "$SID"
	[ "$status" -ne 0 ]
}

@test "default empty threat still produces a valid closed lock" {
	warden_gate_close "$SID"
	run warden_gate_is_closed "$SID"
	[ "$status" -eq 0 ]
	# The lock file must be valid JSON (regression: stray brace from ${2:-{}}).
	jq -e '.state == "closed"' "$(warden_gate_file "$SID")" >/dev/null
}

@test "gates are isolated per session" {
	warden_gate_close "$SID" "$THREAT"
	run warden_gate_is_closed "other-session"
	[ "$status" -ne 0 ]
}

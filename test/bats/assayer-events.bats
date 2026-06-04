#!/usr/bin/env bats

# Validates every emitted assayer.* event against @onlooker-community/schema.
#
# The assayer.* event types ship in @onlooker-community/schema; until the
# installed version includes them, these tests skip rather than fail. Once the
# ecosystem's schema dependency is bumped to a release that carries them, they
# run for real. See plugins/assayer/README.md (Requirements).

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/assayer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export CLAUDE_SESSION_ID="bats-session-$$"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/assayer-events.sh"
}

# Skip when the installed schema predates the assayer.* event types.
_require_assayer_schema() {
	if ! grep -q "assayer.audit.started" \
		"${REPO_ROOT}/node_modules/@onlooker-community/schema/schemas/event.v1.json" 2>/dev/null; then
		skip "installed @onlooker-community/schema has no assayer.* types yet"
	fi
}

_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

# Valid 26-char Crockford Base32 ULID (no I, L, O, or U).
AUDIT_ID="01J0000000000000000000AB34"

@test "assayer.audit.started validates" {
	_require_assayer_schema
	local p
	p=$(jq -n --arg a "$AUDIT_ID" '{audit_id: $a, claim_count: 3, trigger: "stop", command_count: 5}')
	assayer_emit_event "assayer.audit.started" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "assayer.claim.contradicted validates" {
	_require_assayer_schema
	local p
	p=$(jq -n --arg a "$AUDIT_ID" '{
		audit_id: $a,
		claim: "I ran the tests and they all pass.",
		claim_type: "tests_pass",
		evidence_command: "npm test",
		result_excerpt: "1 failed, 32 passed",
		confidence: 0.9
	}')
	assayer_emit_event "assayer.claim.contradicted" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "assayer.claim.unverified validates" {
	_require_assayer_schema
	local p
	p=$(jq -n --arg a "$AUDIT_ID" '{audit_id: $a, claim: "The deploy is healthy.", claim_type: "generic", reason: "no_matching_command"}')
	assayer_emit_event "assayer.claim.unverified" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "assayer.audit.complete validates" {
	_require_assayer_schema
	local p
	p=$(jq -n --arg a "$AUDIT_ID" '{
		audit_id: $a, claim_count: 3, corroborated: 1, contradicted: 1,
		unverified: 1, verdict: "contradictions_found", duration_ms: 4200
	}')
	assayer_emit_event "assayer.audit.complete" "$p"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "emission fails on unknown event type" {
	run assayer_emit_event "assayer.no.such.event" '{"audit_id":"x"}'
	[ "$status" -ne 0 ]
}

@test "assayer_emit_event returns 1 when payload is empty" {
	run assayer_emit_event "assayer.audit.started" ""
	[ "$status" -ne 0 ]
}

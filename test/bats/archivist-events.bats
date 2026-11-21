#!/usr/bin/env bats

# archivist_emit_event: what it writes, and what it refuses to.
#
# archivist-events-substrate.bats pins WHICH emitter this resolves. These pin
# the function's own contract: a well-formed event lands once in the log, and
# every refusal returns 1 and writes nothing, so a caller's `|| true` cannot
# leave a half-built line behind.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	export _HOOK_SESSION_ID="sess-archivist-events"

	source "${PLUGIN_ROOT}/scripts/lib/archivist-events.sh"

	PAYLOAD=$(jq -cn '{plugin: "archivist", artifact_kind: "extract",
		artifact_path: "/tmp/extract.json", artifact_title: "Archivist Extract · sess-arc"}')
}

_lines() { [[ -f "$ONLOOKER_EVENTS_LOG" ]] && grep -c . "$ONLOOKER_EVENTS_LOG" || echo 0; }

@test "emits one schema-valid event carrying the session and payload" {
	archivist_emit_event "onlooker.artifact.ready" "$PAYLOAD" || return 1
	[ "$(_lines)" -eq 1 ] || return 1
	jq -e '.event_type == "onlooker.artifact.ready"
		and .plugin == "archivist"
		and .session_id == "sess-archivist-events"
		and .payload.artifact_kind == "extract"' "$ONLOOKER_EVENTS_LOG" >/dev/null || return 1
	ONLOOKER_DIR="$ONLOOKER_DIR" node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate \
		<"$ONLOOKER_EVENTS_LOG" >/dev/null
}

@test "creates the log directory when it is missing" {
	[ ! -d "$(dirname "$ONLOOKER_EVENTS_LOG")" ] || rm -rf "$(dirname "$ONLOOKER_EVENTS_LOG")"
	archivist_emit_event "onlooker.artifact.ready" "$PAYLOAD" || return 1
	[ "$(_lines)" -eq 1 ]
}

@test "refuses an empty event type and writes nothing" {
	run archivist_emit_event "" "$PAYLOAD"
	[ "$status" -eq 1 ] || return 1
	[ "$(_lines)" -eq 0 ]
}

@test "refuses an empty payload and writes nothing" {
	run archivist_emit_event "onlooker.artifact.ready" ""
	[ "$status" -eq 1 ] || return 1
	[ "$(_lines)" -eq 0 ]
}

@test "refuses a payload that is not JSON and writes nothing" {
	run archivist_emit_event "onlooker.artifact.ready" "{not json"
	[ "$status" -eq 1 ] || return 1
	[ "$(_lines)" -eq 0 ]
}

@test "refuses an event the schema rejects, says why, and writes nothing" {
	expect_emission_rejected archivist_emit_event "archivist.no_such.event" '{"x":1}'
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"schema validation failed for archivist.no_such.event"* ]] || return 1
	[ "$(_lines)" -eq 0 ]
}

@test "falls back to CLAUDE_SESSION_ID, then to unknown, for the session" {
	unset _HOOK_SESSION_ID
	CLAUDE_SESSION_ID="sess-from-skill" archivist_emit_event "onlooker.artifact.ready" "$PAYLOAD" || return 1
	(unset CLAUDE_SESSION_ID; archivist_emit_event "onlooker.artifact.ready" "$PAYLOAD") || return 1
	[ "$(jq -r '.session_id' "$ONLOOKER_EVENTS_LOG" | paste -sd, -)" = "sess-from-skill,unknown" ]
}

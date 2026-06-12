#!/usr/bin/env bats

# Exercises scripts/lib/onlooker-schema.sh — the bash wrappers around the
# canonical event emitter (scripts/lib/onlooker-event.mjs). Events are
# validated against the real installed @onlooker-community/schema.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	load_validate_path
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export ONLOOKER_PLUGIN_NAME="onlooker"
	# shellcheck disable=SC1091
	source "${REPO_ROOT}/scripts/lib/onlooker-schema.sh"
}

_fixture() {
	cat "${REPO_ROOT}/test/fixtures/hook-inputs/${1}"
}

# --- onlooker_append_event -------------------------------------------------

@test "onlooker_append_event appends a parseable line carrying the event_type" {
	local line
	line='{"event_type":"tool.file.read","payload":{"path":"/x"}}'
	run onlooker_append_event "$line"
	[ "$status" -eq 0 ]

	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	# Round-trips through jq (valid JSON) and preserves the event_type.
	[ "$(printf '%s' "$last" | jq -r '.event_type')" = "tool.file.read" ]
}

@test "onlooker_append_event with empty input is a no-op returning 0" {
	run onlooker_append_event ""
	[ "$status" -eq 0 ]
	# No log line written.
	[ ! -s "$ONLOOKER_EVENTS_LOG" ]
}

@test "onlooker_append_event creates parent dirs when missing" {
	# Point the log at a path whose parent does not yet exist.
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/nested/deeper/onlooker-events.jsonl"
	[ ! -d "$(dirname "$ONLOOKER_EVENTS_LOG")" ]

	run onlooker_append_event '{"event_type":"tool.file.read"}'
	[ "$status" -eq 0 ]
	[ -d "$(dirname "$ONLOOKER_EVENTS_LOG")" ]
	[ "$(tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -r '.event_type')" = "tool.file.read" ]
}

@test "onlooker_append_event appends rather than truncating" {
	onlooker_append_event '{"event_type":"tool.file.read"}'
	onlooker_append_event '{"event_type":"tool.shell.exec"}'
	[ "$(wc -l <"$ONLOOKER_EVENTS_LOG" | tr -d ' ')" -eq 2 ]
	[ "$(tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -r '.event_type')" = "tool.shell.exec" ]
}

# --- onlooker_event_from_hook ----------------------------------------------

@test "onlooker_event_from_hook maps a mappable fixture to tool.file.read" {
	local event
	event=$(onlooker_event_from_hook "$(_fixture post-tool-use-read.json)")
	[ -n "$event" ]
	[ "$(printf '%s' "$event" | jq -r '.event_type')" = "tool.file.read" ]
}

@test "onlooker_event_from_hook output validates against the schema" {
	local event
	event=$(onlooker_event_from_hook "$(_fixture post-tool-use-read.json)")
	[ -n "$event" ]
	printf '%s' "$event" | node "$_ONLOOKER_EVENT_JS" validate
}

@test "onlooker_event_from_hook prints empty for an unmappable fixture" {
	local event
	event=$(onlooker_event_from_hook "$(_fixture session-start-startup.json)")
	[ -z "$event" ]
}

@test "onlooker_event_from_hook with empty input returns 0 and prints nothing" {
	run onlooker_event_from_hook ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# --- onlooker_emit_from_hook -----------------------------------------------

@test "onlooker_emit_from_hook writes exactly one tool.file.read line" {
	run onlooker_emit_from_hook "$(_fixture post-tool-use-read.json)"
	[ "$status" -eq 0 ]

	[ "$(wc -l <"$ONLOOKER_EVENTS_LOG" | tr -d ' ')" -eq 1 ]
	[ "$(tail -n 1 "$ONLOOKER_EVENTS_LOG" | jq -r '.event_type')" = "tool.file.read" ]
}

@test "onlooker_emit_from_hook leaves the log empty for an unmappable fixture" {
	run onlooker_emit_from_hook "$(_fixture session-start-startup.json)"
	[ "$status" -eq 0 ]
	[ ! -s "$ONLOOKER_EVENTS_LOG" ]
}

@test "onlooker_emit_from_hook records blocked=true for a failed Bash tool" {
	run onlooker_emit_from_hook "$(_fixture post-tool-use-failure-bash.json)"
	[ "$status" -eq 0 ]

	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ "$(printf '%s' "$last" | jq -r '.event_type')" = "tool.shell.exec" ]
	[ "$(printf '%s' "$last" | jq -r '.payload.blocked')" = "true" ]
}

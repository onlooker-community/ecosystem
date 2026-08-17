#!/usr/bin/env bats

# Validates every emitted cartographer.* event against @onlooker-community/schema.
#
# Both cartographer payloads were off-contract from the day the plugin shipped:
# the published schema described a design that was never built, so every event
# failed validation and emit_safe swallowed the failure with `|| true`. Findings
# still landed on disk, so /cartographer looked healthy and nothing surfaced the
# loss. Nothing here drove a real payload through validation, which is why the
# two sides could drift that far apart (ecosystem-q4d).
#
# So these tests build their payloads with the same
# cartographer_issue_found_payload / cartographer_audit_complete_payload the
# audit calls — not a copy of them. A copy would be free to drift in exactly the
# way the schema did.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export CLAUDE_SESSION_ID="bats-session-$$"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/cartographer-events.sh"
}

# Skip when the installed schema predates the corrected cartographer payloads.
# The old definitions required issue_type/file_path; asserting against them
# would be asserting the bug.
_require_cartographer_schema() {
	if ! grep -q "finding_hash" \
		"${REPO_ROOT}/node_modules/@onlooker-community/schema/schemas/payload/plugins-memory.json" 2>/dev/null; then
		skip "installed @onlooker-community/schema predates the corrected cartographer payloads"
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

# A finding record in the shape the analysis phases produce, which is what
# run_emit reads out of ALL_FINDINGS.
_finding() {
	local type="${1:-undocumented_entity}" severity="${2:-warning}"
	local file_a="${3:-CLAUDE.md}" file_b="${4:-null}"
	jq -cn --arg t "$type" --arg s "$severity" --arg a "$file_a" --argjson b "$file_b" \
		'{type: $t, severity: $s, file_a: $a, file_b: $b,
		  description: "fixture finding", suggested_fix: "document it"}'
}

@test "cartographer.issue.found validates for a single-file finding" {
	_require_cartographer_schema
	cartographer_emit_event "cartographer.issue.found" \
		"$(cartographer_issue_found_payload "$AUDIT_ID" "abc123" "$(_finding)")"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "cartographer.issue.found validates for a two-file finding" {
	_require_cartographer_schema
	cartographer_emit_event "cartographer.issue.found" \
		"$(cartographer_issue_found_payload "$AUDIT_ID" "abc123" \
			"$(_finding contradiction error CLAUDE.md '"AGENTS.md"')")"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "every finding type the analysis phases produce validates" {
	_require_cartographer_schema
	local t
	for t in contradiction stale_ref dead_rule scope_collision undocumented_entity; do
		cartographer_emit_event "cartographer.issue.found" \
			"$(cartographer_issue_found_payload "$AUDIT_ID" "hash-${t}" "$(_finding "$t")")" \
			|| return 1
		_validate_latest_event || return 1
	done
}

@test "cartographer.audit.complete validates" {
	_require_cartographer_schema
	cartographer_emit_event "cartographer.audit.complete" \
		"$(cartographer_audit_complete_payload "$AUDIT_ID" "session_start_first_run" 1 3 8420)"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "every trigger the hooks set validates" {
	_require_cartographer_schema
	local t
	for t in session_start_first_run session_start_interval post_tool_use manual; do
		cartographer_emit_event "cartographer.audit.complete" \
			"$(cartographer_audit_complete_payload "$AUDIT_ID" "$t" 0 0 5)" || return 1
		_validate_latest_event || return 1
	done
}

# The emitted payload is the contract downstream reads, so assert on its
# contents and not merely that it validated. finding_hash in particular is what
# makes at-least-once delivery deduplicable (the plugin's ADR-003).
@test "the emitted payload carries the fields consumers read" {
	_require_cartographer_schema
	cartographer_emit_event "cartographer.issue.found" \
		"$(cartographer_issue_found_payload "$AUDIT_ID" "abc123" \
			"$(_finding contradiction error CLAUDE.md '"AGENTS.md"')")"

	grep '"event_type":"cartographer.issue.found"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e --arg a "$AUDIT_ID" '
			.payload.audit_id == $a
			and .payload.finding_hash == "abc123"
			and .payload.finding_type == "contradiction"
			and .payload.severity == "error"
			and .payload.affected_files == ["CLAUDE.md", "AGENTS.md"]
		' >/dev/null
}

@test "a single-file finding carries exactly one affected file" {
	_require_cartographer_schema
	cartographer_emit_event "cartographer.issue.found" \
		"$(cartographer_issue_found_payload "$AUDIT_ID" "abc123" "$(_finding)")"

	tail -n 1 "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.affected_files == ["CLAUDE.md"]' >/dev/null
}

@test "the retired pre-implementation vocabulary no longer validates" {
	_require_cartographer_schema
	# Guards the direction of the fix: if someone "restores" the old schema,
	# this is the test that objects.
	run cartographer_emit_event "cartographer.issue.found" \
		'{"issue_type":"orphaned_plugin","file_path":"CLAUDE.md","severity":"warning"}'
	[ "$status" -ne 0 ]
}

@test "payload builders reject missing arguments" {
	run cartographer_issue_found_payload "" "abc123" "$(_finding)"
	[ "$status" -ne 0 ] || return 1
	run cartographer_issue_found_payload "$AUDIT_ID" "" "$(_finding)"
	[ "$status" -ne 0 ] || return 1
	run cartographer_audit_complete_payload ""
	[ "$status" -ne 0 ]
}

@test "emission fails on unknown event type" {
	run cartographer_emit_event "cartographer.no.such.event" '{"audit_id":"x"}'
	[ "$status" -ne 0 ]
}

@test "cartographer_emit_event returns 1 when payload is empty" {
	run cartographer_emit_event "cartographer.issue.found" ""
	[ "$status" -ne 0 ]
}

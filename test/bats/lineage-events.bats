#!/usr/bin/env bats

# Validates that lineage.* events pass @onlooker-community/schema validation.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-events.sh"

	export CLAUDE_SESSION_ID="bats-lineage-session-$$"
	PK="proj0123abcd"
	SID="bats-lineage-sid-000"
}

_validate_latest_event() {
	local last
	last=$(tail -n 1 "$ONLOOKER_EVENTS_LOG")
	[ -n "$last" ] || return 1
	printf '%s' "$last" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		node "${REPO_ROOT}/scripts/lib/onlooker-event.mjs" validate >/dev/null
}

@test "lineage.change.recorded validates (full payload)" {
	local p
	p=$(jq -n --arg pk "$PK" --arg sid "$SID" \
		'{project_key:$pk, session_id:$sid, file_path:"src/main.ts", tool:"Edit",
		  operation:"edit", change_id:"01JLNG0000000000000000CHG1", turn:4,
		  tool_use_id:"toolu_1", lines_added:3, lines_removed:1, bytes:142,
		  edit_count:1, content_sha256:"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}')
	lineage_emit_event "lineage.change.recorded" "$p" "$SID"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "lineage.change.recorded validates (minimal Write)" {
	local p
	p=$(jq -n --arg pk "$PK" --arg sid "$SID" \
		'{project_key:$pk, session_id:$sid, file_path:"README.md", tool:"Write", operation:"create"}')
	lineage_emit_event "lineage.change.recorded" "$p" "$SID"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "lineage.query.answered validates" {
	local p
	p=$(jq -n --arg pk "$PK" \
		'{project_key:$pk, file_path:"src/main.ts", matches:2, query:"src/main.ts:42", line:42, resolved_via:"historian"}')
	lineage_emit_event "lineage.query.answered" "$p" "$SID"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "lineage.query.answered validates with no matches" {
	local p
	p=$(jq -n --arg pk "$PK" \
		'{project_key:$pk, file_path:"src/gone.ts", matches:0, resolved_via:"none"}')
	lineage_emit_event "lineage.query.answered" "$p" "$SID"
	run _validate_latest_event
	[ "$status" -eq 0 ]
}

@test "an invalid tool enum is rejected by the schema" {
	local p
	p=$(jq -n --arg pk "$PK" --arg sid "$SID" \
		'{project_key:$pk, session_id:$sid, file_path:"x", tool:"NotebookEdit", operation:"edit"}')
	run lineage_emit_event "lineage.change.recorded" "$p" "$SID"
	[ "$status" -ne 0 ]
}

@test "lineage_emit_event returns nonzero for an unknown event type" {
	run lineage_emit_event "lineage.no_such_event" '{"project_key":"x"}' "$SID"
	[ "$status" -ne 0 ]
}

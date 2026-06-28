#!/usr/bin/env bats

# Exercises the PostToolUse hook end-to-end against an isolated $ONLOOKER_DIR.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/lineage-post-tool-use.sh"
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")" "${ONLOOKER_DIR}/session-trackers"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-project-key.sh"

	REPO="${BATS_TEST_TMPDIR}/proj"
	mkdir -p "$REPO"
	git init -q "$REPO" 2>/dev/null
	git -C "$REPO" remote add origin https://example.com/onlooker/lineage-test.git 2>/dev/null
	KEY=$(lineage_project_key "$REPO")
	SID="bats-lin-001"
}

_enable() {
	:
}

_ledger() { printf '%s/lineage/%s/changes.jsonl' "$ONLOOKER_DIR" "$KEY"; }

# _run <tool> <file_path> <tool_input_json>
_run() {
	local tool="$1" file="$2" ti="$3"
	jq -nc --arg sid "$SID" --arg cwd "$REPO" --arg tool "$tool" --argjson ti "$ti" \
		'{session_id:$sid, cwd:$cwd, tool_name:$tool, tool_use_id:"toolu_x", transcript_path:"", tool_input:$ti}' \
		> "${BATS_TEST_TMPDIR}/in.json"
	run bash "$HOOK" < "${BATS_TEST_TMPDIR}/in.json"
}

@test "records an Edit change into the project ledger" {
	_enable
	_run Edit "${REPO}/foo.py" "$(jq -nc --arg f "${REPO}/foo.py" '{file_path:$f, old_string:"x = 1", new_string:"x = 2"}')"
	[ "$status" -eq 0 ]
	[ -f "$(_ledger)" ]
	[ "$(jq -rs '.[0].file_path' "$(_ledger)")" = "${REPO}/foo.py" ]
	[ "$(jq -rs '.[0].tool' "$(_ledger)")" = "Edit" ]
}

@test "records a single-file MultiEdit (top-level file_path)" {
	_enable
	_run MultiEdit "${REPO}/foo.py" "$(jq -nc --arg f "${REPO}/foo.py" \
		'{file_path:$f, edits:[{old_string:"a", new_string:"a1"},{old_string:"b", new_string:"b1"}]}')"
	[ "$status" -eq 0 ]
	[ -f "$(_ledger)" ]
	[ "$(jq -rs '.[0].file_path' "$(_ledger)")" = "${REPO}/foo.py" ]
	[ "$(jq -rs '.[0].tool' "$(_ledger)")" = "MultiEdit" ]
	[ "$(jq -rs '.[0].operation' "$(_ledger)")" = "multi_edit" ]
}

@test "skips a MultiEdit whose edits span multiple distinct files" {
	_enable
	# Hypothetical per-edit-file_path shape spanning two files — skip to avoid misattribution.
	local ti
	ti=$(jq -nc --arg a "${REPO}/a.py" --arg b "${REPO}/b.py" \
		'{edits:[{file_path:$a, old_string:"x", new_string:"x1"},{file_path:$b, old_string:"y", new_string:"y1"}]}')
	_run MultiEdit "${REPO}/a.py" "$ti"
	[ "$status" -eq 0 ]
	[ ! -f "$(_ledger)" ]
}

@test "records the turn number from the session tracker" {
	_enable
	printf '%s' '{"turn_number":7}' > "${ONLOOKER_DIR}/session-trackers/${SID}"
	_run Write "${REPO}/bar.py" "$(jq -nc --arg f "${REPO}/bar.py" '{file_path:$f, content:"print(1)"}')"
	[ "$(jq -rs '.[0].turn' "$(_ledger)")" = "7" ]
}

@test "writes nothing when lineage is disabled" {
	_run Edit "${REPO}/foo.py" "$(jq -nc --arg f "${REPO}/foo.py" '{file_path:$f, old_string:"a", new_string:"b"}')"
	[ "$status" -eq 0 ]
	[ ! -d "${ONLOOKER_DIR}/lineage" ]
}

@test "skips paths matching ignore_globs" {
	_enable
	mkdir -p "${REPO}/node_modules"
	_run Write "${REPO}/node_modules/x.js" "$(jq -nc --arg f "${REPO}/node_modules/x.js" '{file_path:$f, content:"y"}')"
	[ "$status" -eq 0 ]
	[ ! -f "$(_ledger)" ]
}

@test "skips files outside the repo" {
	_enable
	mkdir -p "${BATS_TEST_TMPDIR}/outside"
	local f="${BATS_TEST_TMPDIR}/outside/x.js"
	_run Write "$f" "$(jq -nc --arg f "$f" '{file_path:$f, content:"y"}')"
	[ "$status" -eq 0 ]
	[ ! -f "$(_ledger)" ]
}

@test "emits lineage.change.recorded" {
	_enable
	_run Edit "${REPO}/foo.py" "$(jq -nc --arg f "${REPO}/foo.py" '{file_path:$f, old_string:"a", new_string:"b"}')"
	run grep -c '"event_type":"lineage.change.recorded"' "$ONLOOKER_EVENTS_LOG"
	[ "$output" -ge 1 ]
}

@test "a distinct subagent session_id is recorded as-is" {
	_enable
	SID="bats-subagent-999"
	_run Edit "${REPO}/foo.py" "$(jq -nc --arg f "${REPO}/foo.py" '{file_path:$f, old_string:"a", new_string:"b"}')"
	[ "$(jq -rs '.[0].session_id' "$(_ledger)")" = "bats-subagent-999" ]
}

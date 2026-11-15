#!/usr/bin/env bats

# The Stop-time nudge toward /tribunal (docs/superpowers/specs/
# 2026-11-15-tribunal-nudge-design.md). It makes no model call, prints at most
# one {"systemMessage": ...}, counts the files THIS session's transcript shows
# it editing (committed or not), and speaks again only when that grows.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/tribunal-stop-nudge.sh"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name "Test"
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	git -C "$REPO" commit -q --allow-empty -m seed
	mkdir -p "${REPO}/.claude"
	printf '.claude/\n' > "${REPO}/.git/info/exclude"
	PROJECT_KEY=$(onlooker_project_key "$REPO")

	# Any model call fails the test.
	CLAUDE_MARKER="${BATS_TEST_TMPDIR}/claude-was-invoked"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	printf '#!/usr/bin/env bash\nprintf invoked >> %q\nexit 1\n' "$CLAUDE_MARKER" > "${STUB_BIN}/claude"
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	SID="sess-nudge"
}

_settings() { # <json for .tribunal>
	jq -cn --argjson t "$1" '{tribunal: $t}' > "${REPO}/.claude/settings.json"
}

_transcript() { printf '%s' "${BATS_TEST_TMPDIR}/transcript-$1.jsonl"; }

_edit() { # <session> <relative path> — create the file and record the edit
	mkdir -p "$(dirname "${REPO}/$2")"
	printf 'x\n' >> "${REPO}/$2"
	jq -cn --arg p "${REPO}/$2" \
		'{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "toolu_1", name: "Edit", input: {file_path: $p}}]}}' \
		>> "$(_transcript "$1")"
}

_edits() { # <session> <count> — that many ordinary files
	local i=1
	while [[ $i -le $2 ]]; do
		_edit "$1" "src/f${i}.txt"
		i=$((i + 1))
	done
}

_stop() { # <session> [transcript override]
	local tp="${2-$(_transcript "$1")}"
	[[ -n "${2-}" || -f "$tp" ]] || printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$tp"
	local input
	input=$(jq -cn --arg cwd "$REPO" --arg tp "$tp" --arg sid "$1" \
		'{cwd: $cwd, transcript_path: $tp, session_id: $sid, hook_event_name: "Stop"}')
	run bash -c "printf '%s' '$input' | '$HOOK'"
}

_state_path() { printf '%s' "${ONLOOKER_DIR}/tribunal/${PROJECT_KEY}/nudge-${1:-$SID}.json"; }

_state() { cat "${ONLOOKER_DIR}/tribunal/${PROJECT_KEY}/nudge-${1:-$SID}.json"; }

_message() { printf '%s' "$output" | jq -r '.systemMessage'; }

_only_system_message() {
	[[ -z "$output" ]] && return 0
	printf '%s' "$output" | jq -e 'type == "object" and keys == ["systemMessage"]' >/dev/null
}

@test "fewer than min_files ordinary files stays quiet" {
	_edits "$SID" 7
	_stop "$SID"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["below_threshold"]' >/dev/null
}

@test "min_files files nudges, names the count, and prints only systemMessage" {
	_edits "$SID" 8
	_stop "$SID"
	[ "$status" -eq 0 ] || return 1
	_only_system_message || return 1
	[[ "$(_message)" == "tribunal: this session changed 8 files."* ]] || return 1
	_state | jq -e '.files == 8 and .sensitive == []' >/dev/null
}

@test "edits that were then committed still count" {
	_edits "$SID" 8
	git -C "$REPO" add -A && git -C "$REPO" commit -qm work
	_stop "$SID"
	[[ "$(_message)" == *"changed 8 files"* ]]
}

@test "a workflow file alone nudges as sensitive, in any case; a lockfile does not" {
	_edit "$SID" "pnpm-lock.yaml"
	_stop "$SID"
	[ -z "$output" ] || return 1
	_edit "$SID" ".GitHub/Workflows/CI.yml"
	_stop "$SID"
	[[ "$(_message)" == *"1 sensitive (.GitHub/Workflows/CI.yml)"* ]]
}

@test "a second Stop with no change is quiet; growth speaks again" {
	_edit "$SID" "db/migrations/001.sql"
	_stop "$SID"
	[ -n "$output" ] || return 1
	_stop "$SID"
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["unchanged"]' >/dev/null || return 1
	_edit "$SID" "db/migrations/002.sql"
	_stop "$SID"
	[[ "$(_message)" == *"2 sensitive"* ]]
}

@test "a repeated skip is not recorded twice, and a nudge keeps skips_reported" {
	_edits "$SID" 2
	_stop "$SID"
	_stop "$SID"
	_state | jq -e '.skips_reported == ["below_threshold"]' >/dev/null || return 1
	_edits "$SID" 8
	_stop "$SID"
	[ -n "$output" ] || return 1
	# _edits reuses src/f1..fN, so the second call brings the total to 8, not 10.
	_state | jq -e '.skips_reported == ["below_threshold"] and .files == 8' >/dev/null
}

@test "/tribunal in this session silences it, as a Skill call or typed" {
	_edits "$SID" 8
	jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "t", name: "Skill", input: {skill: "tribunal:tribunal"}}]}}' >> "$(_transcript "$SID")"
	_stop "$SID"
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["tribunal_ran"]' >/dev/null || return 1

	_edits "typed" 8
	jq -cn '{type: "user", message: {role: "user", content: "<command-name>/tribunal</command-name>"}}' >> "$(_transcript typed)"
	_stop "typed"
	[ -z "$output" ]
}

@test "disabled: quiet, and nothing written or emitted" {
	_settings '{"nudge": {"enabled": false}}'
	_edits "$SID" 8
	_stop "$SID"
	[ -z "$output" ] || return 1
	[ ! -e "${ONLOOKER_DIR}/tribunal/${PROJECT_KEY}/nudge-${SID}.json" ] || return 1
	! grep -q 'tribunal.nudge' "$ONLOOKER_EVENTS_LOG" 2>/dev/null
}

@test "with the paid gate on, the nudge stays quiet" {
	_settings '{"stop_hook": {"enabled": true, "skip_if_no_file_changes": true}}'
	# The gate itself is a different hook; this runs only the nudge.
	_edits "$SID" 8
	_stop "$SID"
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["gate_enabled"]' >/dev/null
}

@test "a project sensitive_globs replaces the defaults" {
	_settings '{"nudge": {"sensitive_globs": ["plugins/*/scripts/hooks/*.sh"]}}'
	_edit "$SID" ".github/workflows/ci.yml"
	_stop "$SID"
	[ -z "$output" ] || return 1
	_edit "$SID" "plugins/x/scripts/hooks/h.sh"
	_stop "$SID"
	[[ "$(_message)" == *"(plugins/x/scripts/hooks/h.sh)"* ]]
}

@test "min_files 0 turns the size trigger off; a bad min_files reads as 8" {
	_settings '{"nudge": {"min_files": 0}}'
	_edits "$SID" 30
	_stop "$SID"
	[ -z "$output" ] || return 1
	_settings '{"nudge": {"min_files": "lots"}}'
	_edits "other" 8
	_stop "other"
	[[ "$(_message)" == *"changed 8 files"* ]]
}

@test "an empty session id writes no state file" {
	_edits "" 8
	_stop "" "$(_transcript "")"
	[ "$status" -eq 0 ] || return 1
	_only_system_message || return 1
	[[ "$(_message)" == "tribunal: "* ]] || return 1
	[ -z "$(find "${ONLOOKER_DIR}/tribunal" -name 'nudge-*' 2>/dev/null)" ]
}

@test "another session's dirty files never count" {
	_edits "author" 8
	_edit "$SID" "src/mine.txt"
	_stop "$SID"
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["below_threshold"]' >/dev/null
}

@test "no transcript is a skip, recorded" {
	_stop "$SID" "${BATS_TEST_TMPDIR}/missing.jsonl"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["no_transcript"]' >/dev/null
}

@test "no model call, ever" {
	_edits "$SID" 8
	_edit "$SID" "auth/login.ts"
	_stop "$SID"
	[ "$status" -eq 0 ] || return 1
	_only_system_message || return 1
	[[ "$(_message)" == "tribunal: "* ]] || return 1
	[ ! -e "$CLAUDE_MARKER" ]
}

@test "/tribunal run early in a very long session still silences it" {
	jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "t", name: "Skill", input: {skill: "tribunal"}}]}}' > "$(_transcript "$SID")"
	# The scan output must outrun the pipe buffer (64KB) for grep -q to SIGPIPE its writer.
	local i=1
	while [[ $i -le 1500 ]]; do
		printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"%s/src/long-session-file-%s.txt"}}]}}\n' "$REPO" "$i"
		i=$((i + 1))
	done >> "$(_transcript "$SID")"
	_stop "$SID"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ] || return 1
	_state | jq -e '.skips_reported == ["tribunal_ran"]' >/dev/null
}

@test "state that decide cannot read exits quietly and records no empty skip" {
	_edits "$SID" 8
	mkdir -p "$(dirname "$(_state_path)")"
	# decide errors on this (2 * {}), and prints nothing.
	printf '{"files":{}}\n' > "$(_state_path)"
	_stop "$SID"
	[ "$status" -eq 0 ] || return 1
	[ -z "$output" ] || return 1
	_state | jq -e '(.skips_reported // []) | index("") == null' >/dev/null
}

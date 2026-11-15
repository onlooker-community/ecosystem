#!/usr/bin/env bats

# The nudge's lib: the one-pass transcript scan, the decision, the message and
# the state file. Fixture shapes come from a real transcript: a Skill call
# carries input.skill, a typed command shows as <command-name>/x</command-name>.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	# shellcheck source=../../plugins/tribunal/scripts/lib/tribunal-session-files.sh
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-session-files.sh"
	# shellcheck source=../../plugins/tribunal/scripts/lib/tribunal-nudge.sh
	source "${PLUGIN_ROOT}/scripts/lib/tribunal-nudge.sh"
	T="${BATS_TEST_TMPDIR}/transcript.jsonl"
	: > "$T"
}

_tool() { # <name> <input-json>
	jq -cn --arg n "$1" --argjson in "$2" \
		'{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "toolu_1", name: $n, input: $in}]}}' >> "$T"
}

_typed() { # <command>
	jq -cn --arg c "$1" \
		'{type: "user", message: {role: "user", content: ("<command-message>x</command-message>\n<command-name>" + $c + "</command-name>")}}' >> "$T"
}

@test "scan lists each write-class edit's absolute path" {
	_tool Edit '{"file_path":"/r/a.txt"}'
	_tool Write '{"file_path":"/r/b.txt"}'
	_tool NotebookEdit '{"notebook_path":"/r/c.ipynb"}'
	_tool Read '{"file_path":"/r/d.txt"}'
	run tribunal_nudge_scan "$T"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "$(printf 'E\t/r/a.txt\nE\t/r/b.txt\nE\t/r/c.ipynb')" ]
}

@test "scan marks a Skill call to tribunal or tribunal:tribunal" {
	_tool Skill '{"skill":"tribunal:tribunal","args":"x"}'
	run tribunal_nudge_scan "$T"
	[ "$output" = "T" ] || return 1
	: > "$T"
	_tool Skill '{"skill":"tribunal"}'
	run tribunal_nudge_scan "$T"
	[ "$output" = "T" ]
}

@test "scan marks a typed /tribunal, and ignores other skills and mentions" {
	_typed "/tribunal"
	run tribunal_nudge_scan "$T"
	[ "$output" = "T" ] || return 1
	: > "$T"
	_tool Skill '{"skill":"git-workflow:commit"}'
	_typed "/pickup"
	jq -cn '{type: "user", message: {role: "user", content: "should I run /tribunal?"}}' >> "$T"
	run tribunal_nudge_scan "$T"
	[ -z "$output" ]
}

@test "scan skips lines that are not JSON" {
	printf 'not json "tool_use"\n' >> "$T"
	_tool Edit '{"file_path":"/r/a.txt"}'
	run tribunal_nudge_scan "$T"
	[ "$output" = "$(printf 'E\t/r/a.txt')" ]
}

@test "paths_in_worktree keeps paths inside the root, relative and deduplicated" {
	mkdir -p "${BATS_TEST_TMPDIR}/wt/sub" "${BATS_TEST_TMPDIR}/other"
	run tribunal_paths_in_worktree "${BATS_TEST_TMPDIR}/wt" <<EOF
${BATS_TEST_TMPDIR}/wt/sub/a.txt
${BATS_TEST_TMPDIR}/wt/sub/a.txt
${BATS_TEST_TMPDIR}/wt/b.txt
${BATS_TEST_TMPDIR}/other/c.txt
${BATS_TEST_TMPDIR}/gone/d.txt
EOF
	[ "$output" = "$(printf 'b.txt\nsub/a.txt')" ]
}

_decide() { tribunal_nudge_decide "$@" | jq -c .; }

@test "decide: below both triggers skips below_threshold" {
	[ "$(_decide 3 '[]' 8 '{}')" = '{"action":"skip","reason":"below_threshold"}' ]
}

@test "decide: reaching min_files nudges on size" {
	[ "$(_decide 8 '[]' 8 '{}')" = '{"action":"nudge","trigger":"size"}' ]
}

@test "decide: a sensitive file nudges on sensitive, which wins over size" {
	[ "$(_decide 1 '["auth/a.ts"]' 8 '{}')" = '{"action":"nudge","trigger":"sensitive"}' ] || return 1
	[ "$(_decide 9 '["auth/a.ts"]' 8 '{}')" = '{"action":"nudge","trigger":"sensitive"}' ]
}

@test "decide: min_files 0 turns the size trigger off" {
	[ "$(_decide 50 '[]' 0 '{}')" = '{"action":"skip","reason":"below_threshold"}' ]
}

@test "decide: after a nudge, no growth is unchanged" {
	[ "$(_decide 9 '["auth/a.ts"]' 8 '{"files":9,"sensitive":["auth/a.ts"]}')" = '{"action":"skip","reason":"unchanged"}' ]
}

@test "decide: a new sensitive file, or a doubled count, is grew" {
	[ "$(_decide 9 '["auth/a.ts","auth/b.ts"]' 8 '{"files":9,"sensitive":["auth/a.ts"]}')" = '{"action":"nudge","trigger":"grew"}' ] || return 1
	[ "$(_decide 17 '[]' 8 '{"files":9,"sensitive":[]}')" = '{"action":"skip","reason":"unchanged"}' ] || return 1
	[ "$(_decide 18 '[]' 8 '{"files":9,"sensitive":[]}')" = '{"action":"nudge","trigger":"grew"}' ]
}

@test "decide: skips_reported alone does not count as a prior nudge" {
	[ "$(_decide 8 '[]' 8 '{"skips_reported":["below_threshold"]}')" = '{"action":"nudge","trigger":"size"}' ]
}

@test "decide and message, called directly, do not abort the caller" {
	tribunal_nudge_decide 3 '[]' 8 '{}' > "${BATS_TEST_TMPDIR}/d.json"
	[ "$(jq -c . "${BATS_TEST_TMPDIR}/d.json")" = '{"action":"skip","reason":"below_threshold"}' ] || return 1
	tribunal_nudge_message 1 '[]' > "${BATS_TEST_TMPDIR}/m.txt"
	[ "$(cat "${BATS_TEST_TMPDIR}/m.txt")" = "tribunal: this session changed 1 file. Worth a jury? /tribunal runs several judge models; type it to start." ]
}

@test "message names the count, up to three sensitive paths, and the rest" {
	run tribunal_nudge_message 9 '["a","b","c","d","e"]'
	[ "$output" = "tribunal: this session changed 9 files, 5 sensitive (a, b, c and 2 more). Worth a jury? /tribunal runs several judge models; type it to start." ]
}

@test "message leaves out the sensitive clause for size alone, and says file for one" {
	run tribunal_nudge_message 8 '[]'
	[ "$output" = "tribunal: this session changed 8 files. Worth a jury? /tribunal runs several judge models; type it to start." ] || return 1
	run tribunal_nudge_message 1 '["auth/a.ts"]'
	[ "$output" = "tribunal: this session changed 1 file, 1 sensitive (auth/a.ts). Worth a jury? /tribunal runs several judge models; type it to start." ]
}

@test "state: missing or unparseable reads as {}, and a write round-trips" {
	S="${BATS_TEST_TMPDIR}/state/nudge-s.json"
	[ "$(tribunal_nudge_state_read "$S")" = "{}" ] || return 1
	mkdir -p "${S%/*}"
	printf 'not json' > "$S"
	[ "$(tribunal_nudge_state_read "$S")" = "{}" ] || return 1
	tribunal_nudge_state_write "$S" '{"files":2}'
	[ "$(tribunal_nudge_state_read "$S")" = '{"files":2}' ] || return 1
	[ ! -e "${S}.tmp" ]
}

@test "state: an unparseable file, read directly, does not abort the caller" {
	S="${BATS_TEST_TMPDIR}/nudge-bad.json"
	printf 'not json' > "$S"
	tribunal_nudge_state_read "$S" > "${BATS_TEST_TMPDIR}/out.json"
	[ "$(cat "${BATS_TEST_TMPDIR}/out.json")" = "{}" ]
}

@test "state: an empty path writes nothing" {
	tribunal_nudge_state_write "" '{"files":2}'
	[ -z "$(find "$BATS_TEST_TMPDIR" -name 'nudge-*')" ]
}

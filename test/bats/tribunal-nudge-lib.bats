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

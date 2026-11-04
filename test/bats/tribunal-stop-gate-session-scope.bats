#!/usr/bin/env bats

# Two sessions, one checkout: the Stop gate judges only this session's work
# (ecosystem-449.42, ONL-25).
#
# The gate builds the judge's prompt from this session's transcript and a diff
# stat of the worktree. A worktree can hold more than one session's changes at
# a time, so session B's Stop handed the judge B's narrative next to A's code.
# The same whole-tree read decided whether the gate ran at all, so an idle
# session in a checkout another session had left dirty paid for a `claude -p`
# on every Stop, to judge work it never did.
#
# 449.37 pointed those reads at the right TREE. This is about SCOPE within it.
# The gate now takes the files this session edited from its own transcript
# (Edit, Write, MultiEdit, NotebookEdit), the way compass takes paths from the
# tool input, and judges only those that are still dirty.
#
# Known gap, kept on purpose: a file this session changed only through Bash is
# not in its transcript as an edit, so it is not judged. Showing the judge too
# little is the safe error; showing it another session's work is the one this
# file exists to prevent.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/tribunal"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/tribunal-stop-gate.sh"
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
	printf 'a\n' > "${REPO}/a.txt"
	printf 'b\n' > "${REPO}/b.txt"
	git -C "$REPO" add a.txt b.txt
	git -C "$REPO" commit -qm seed
	REPO_REAL=$(cd "$REPO" && pwd -P)

	mkdir -p "${REPO}/.claude"
	_settings true

	CLAUDE_MARKER="${BATS_TEST_TMPDIR}/claude-was-invoked"
	CLAUDE_PROMPT="${BATS_TEST_TMPDIR}/claude-prompt"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
printf 'invoked\n' >> "${CLAUDE_MARKER}"
cat > "${CLAUDE_PROMPT}"
printf '%s' '{"score":0.9,"passed":true,"judge_type":"standard","feedback_summary":"ok","confidence":0.9}'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	AUTHOR="sess-author"
	BYSTANDER="sess-bystander"
}

# _settings <skip_if_no_file_changes>
_settings() {
	jq -cn --argjson skip "$1" '{tribunal: {stop_hook: {enabled: true, skip_if_no_file_changes: $skip}}}' \
		> "${REPO}/.claude/settings.json"
	printf '.claude/\n' > "${REPO}/.git/info/exclude"
}

_transcript() {
	local t="${BATS_TEST_TMPDIR}/transcript-$1.jsonl"
	[[ -f "$t" ]] || printf '{"type":"user","message":{"role":"user","content":"hi"}}\n' > "$t"
	printf '%s' "$t"
}

# _edit <session> <tool> <absolute path> — record a write-class tool call in
# the session's transcript, in the shape Claude Code writes it.
_edit() {
	local t key=file_path
	t=$(_transcript "$1")
	[[ "$2" == "NotebookEdit" ]] && key=notebook_path
	jq -cn --arg tool "$2" --arg key "$key" --arg p "$3" \
		'{type: "assistant", message: {role: "assistant", content: [
			{type: "text", text: "editing"},
			{type: "tool_use", id: "toolu_1", name: $tool, input: {($key): $p}}
		]}}' >> "$t"
}

# _stop <session> — run the gate as that session's Stop.
_stop() {
	local input
	input=$(jq -cn --arg cwd "$REPO" --arg tp "$(_transcript "$1")" --arg sid "$1" \
		'{cwd: $cwd, transcript_path: $tp, session_id: $sid, hook_event_name: "Stop"}')
	run bash -c "printf '%s' '$input' | '$HOOK'"
}

_skip_reason() {
	grep '"event_type":"tribunal.gate.skipped"' "$ONLOOKER_EVENTS_LOG" 2>/dev/null \
		| tail -n 1 | jq -r '.payload.reason'
}

@test "an idle session in a checkout another session left dirty spends no model call" {
	printf 'author work\n' >> "${REPO}/a.txt"
	_edit "$AUTHOR" Edit "${REPO}/a.txt"

	_stop "$BYSTANDER"
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$CLAUDE_MARKER" ] || return 1
	[ "$(_skip_reason)" = "no_file_changes" ]
}

@test "the judge is shown this session's files and not the other session's" {
	printf 'author work\n' >> "${REPO}/a.txt"
	_edit "$AUTHOR" Edit "${REPO}/a.txt"
	printf 'bystander work\n' >> "${REPO}/b.txt"
	_edit "$BYSTANDER" Edit "${REPO}/b.txt"

	_stop "$BYSTANDER"
	[ "$status" -eq 0 ] || return 1
	[ -f "$CLAUDE_PROMPT" ] || return 1
	grep -q 'b.txt' "$CLAUDE_PROMPT" || return 1
	! grep -q 'a.txt' "$CLAUDE_PROMPT"
}

@test "a file this session created with Write is judged though git does not track it" {
	printf 'new\n' > "${REPO}/new.txt"
	_edit "$AUTHOR" Write "${REPO}/new.txt"

	_stop "$AUTHOR"
	[ -f "$CLAUDE_PROMPT" ] || return 1
	grep -q 'new.txt' "$CLAUDE_PROMPT"
}

@test "MultiEdit and NotebookEdit paths count as this session's changes" {
	printf 'multi\n' >> "${REPO}/a.txt"
	_edit "$AUTHOR" MultiEdit "${REPO}/a.txt"
	printf '{}\n' > "${REPO}/nb.ipynb"
	_edit "$AUTHOR" NotebookEdit "${REPO}/nb.ipynb"

	_stop "$AUTHOR"
	[ -f "$CLAUDE_PROMPT" ] || return 1
	grep -q 'a.txt' "$CLAUDE_PROMPT" || return 1
	grep -q 'nb.ipynb' "$CLAUDE_PROMPT"
}

@test "edits outside the worktree are not changes to judge" {
	# A memory file under the config dir is a Write the transcript records, but
	# it is not work in this checkout.
	mkdir -p "${HOME}/.claude/memory"
	printf 'note\n' > "${HOME}/.claude/memory/note.md"
	_edit "$BYSTANDER" Write "${HOME}/.claude/memory/note.md"
	printf 'author work\n' >> "${REPO}/a.txt"

	_stop "$BYSTANDER"
	[ "$status" -eq 0 ] || return 1
	[ ! -f "$CLAUDE_MARKER" ] || return 1
	[ "$(_skip_reason)" = "no_file_changes" ]
}

@test "a file this session edited and then committed is no longer a change" {
	printf 'committed work\n' >> "${REPO}/b.txt"
	_edit "$BYSTANDER" Edit "${REPO}/b.txt"
	git -C "$REPO" commit -qam "bystander commits"
	printf 'author work\n' >> "${REPO}/a.txt"

	_stop "$BYSTANDER"
	[ ! -f "$CLAUDE_MARKER" ] || return 1
	[ "$(_skip_reason)" = "no_file_changes" ]
}

@test "a transcript path in physical form still matches a logical cwd" {
	# macOS temp dirs sit behind /var -> /private/var. Whichever spelling the
	# transcript recorded, it names the same file.
	printf 'bystander work\n' >> "${REPO}/b.txt"
	_edit "$BYSTANDER" Edit "${REPO_REAL}/b.txt"

	_stop "$BYSTANDER"
	[ -f "$CLAUDE_PROMPT" ] || return 1
	grep -q 'b.txt' "$CLAUDE_PROMPT"
}

@test "with skip_if_no_file_changes off, an idle session is judged without another session's diff" {
	_settings false
	printf 'author work\n' >> "${REPO}/a.txt"
	_edit "$AUTHOR" Edit "${REPO}/a.txt"

	_stop "$BYSTANDER"
	[ -f "$CLAUDE_PROMPT" ] || return 1
	! grep -q 'a.txt' "$CLAUDE_PROMPT"
}

@test "the advisory verdict records how many dirty files were left out" {
	printf 'author work\n' >> "${REPO}/a.txt"
	_edit "$AUTHOR" Edit "${REPO}/a.txt"
	printf 'bystander work\n' >> "${REPO}/b.txt"
	_edit "$BYSTANDER" Edit "${REPO}/b.txt"

	_stop "$BYSTANDER"
	local key verdict
	key=$(onlooker_project_key "$REPO")
	verdict="${ONLOOKER_DIR}/tribunal/${key}/stop-${BYSTANDER}.json"
	[ -f "$verdict" ] || return 1
	jq -e '.session_files == 1 and .foreign_dirty_files == 1' "$verdict" >/dev/null
}

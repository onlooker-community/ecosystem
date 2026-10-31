#!/usr/bin/env bats

# A change no session can be shown to have made (ONL-26, ecosystem-449.47).
#
# The Bash branch records whatever moved in the tree since the shared baseline
# last advanced, under the session whose hook happened to run. The baseline
# only advances when a lineage hook runs, so ANY change with no hook behind it
# -- an editor save, a checkout, a script outside Claude, a session still on an
# older plugin -- is claimed by whichever session next runs a shell command. In
# the field a session's first `ls` claimed another session's +182/-0 runbook,
# twelve minutes after it was written (2026-09-07).
#
# Claude Code reports how long a Bash call took (duration_ms), so the hook can
# bound when the command started. A changed file whose mtime is older than that
# was already on disk before the command ran; the command cannot have written
# it. Such a record is kept, since the change is real, but marked unknown and
# stripped of the observer's session and transcript so /lineage has no prompt
# to resolve for it.
#
# Every test seeds the bystander's baseline BEFORE the change, for the reason
# lineage-cross-session.bats gives: written the other way round, a first Bash
# call seeds and records nothing, and the test passes against broken code.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")" "${ONLOOKER_DIR}/session-trackers"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/lineage-post-tool-use.sh"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-redact.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-record.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-query.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name "Test"
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	printf 'one\n' > "${REPO}/tracked.txt"
	git -C "$REPO" add tracked.txt
	git -C "$REPO" commit -qm seed

	KEY=$(onlooker_project_key "$REPO")
	LEDGER="${ONLOOKER_DIR}/lineage/${KEY}/changes.jsonl"

	AUTHOR="sess-author"
	BYSTANDER="sess-bystander"
}

# _bash <session> <command> [duration_ms]
#
# duration_ms is what Claude Code reports on a Bash PostToolUse. Omitting it
# reproduces a payload without timing, which must keep the old behavior.
_bash() {
	jq -cn --arg cwd "$REPO" --arg sid "$1" --arg cmd "$2" --arg d "${3:-}" \
		'{cwd: $cwd, session_id: $sid, tool_name: "Bash",
		  transcript_path: "/tmp/transcript-\($sid).jsonl",
		  tool_input: {command: $cmd}, hook_event_name: "PostToolUse"}
		 + (if $d == "" then {} else {duration_ms: ($d | tonumber)} end)' \
		> "${BATS_TEST_TMPDIR}/in.json"
	bash "$HOOK" < "${BATS_TEST_TMPDIR}/in.json"
}

# _age <relative-path> <seconds-ago>: set a file's mtime into the past, the way
# a change made before the observing command started looks on disk.
_age() {
	python3 -c 'import os, sys, time
t = time.time() - int(sys.argv[2])
os.utime(sys.argv[1], (t, t))' "${REPO}/$1" "$2"
}

_record_for() {
	jq -c --arg f "$(cd "$REPO" && pwd -P)/$1" 'select(.file_path == $f)' "$LEDGER" 2>/dev/null | tail -1
}

@test "a change that predates the observing command is recorded as unknown, not under the observer" {
	_bash "$BYSTANDER" "echo seed" 40
	# Written with no lineage hook behind it, a minute before the bystander's
	# command, which took 40ms.
	printf 'ghost\n' > "${REPO}/runbook.md"
	_age runbook.md 60
	_bash "$BYSTANDER" "ls" 40

	local rec
	rec=$(_record_for runbook.md)
	[ -n "$rec" ] || return 1
	printf '%s' "$rec" | jq -e --arg obs "$BYSTANDER" '
		.authorship == "unknown"
		and .authorship_reason == "predates_call"
		and .observed_by_session_id == $obs
		and (has("session_id") | not)
		and (has("transcript_path") | not)' >/dev/null
}

@test "the bus event for an unknown change names no author either" {
	_bash "$BYSTANDER" "echo seed" 40
	printf 'ghost\n' > "${REPO}/runbook.md"
	_age runbook.md 60
	_bash "$BYSTANDER" "ls" 40

	grep '"event_type":"lineage.change.recorded"' "$ONLOOKER_EVENTS_LOG" | tail -1 \
		| jq -e --arg obs "$BYSTANDER" '
			.payload.authorship == "unknown"
			and .payload.authorship_reason == "predates_call"
			and .payload.observed_by_session_id == $obs
			and (.payload | has("session_id") | not)' >/dev/null
}

@test "a genuine shell edit is still recorded under its own session" {
	_bash "$AUTHOR" "echo seed" 40
	printf 'two\n' >> "${REPO}/tracked.txt"
	_bash "$AUTHOR" "printf 'two\n' >> tracked.txt" 40

	local rec
	rec=$(_record_for tracked.txt)
	[ -n "$rec" ] || return 1
	printf '%s' "$rec" | jq -e --arg s "$AUTHOR" '
		.session_id == $s and (has("authorship") | not)' >/dev/null
}

@test "a long command that wrote early in its run keeps its authorship" {
	# The file is 30 seconds old, but the command ran for 31: it started before
	# the write, so it can have made it.
	_bash "$AUTHOR" "echo seed" 40
	printf 'built\n' > "${REPO}/out.txt"
	_age out.txt 30
	_bash "$AUTHOR" "make build" 31000

	_record_for out.txt | jq -e --arg s "$AUTHOR" '.session_id == $s' >/dev/null
}

@test "one call splits a batch: the old file is unknown, the new one is the session's" {
	_bash "$BYSTANDER" "echo seed" 40
	printf 'ghost\n' > "${REPO}/old.md"
	_age old.md 120
	printf 'fresh\n' > "${REPO}/new.md"
	_bash "$BYSTANDER" "printf fresh > new.md" 40

	_record_for old.md | jq -e '.authorship == "unknown"' >/dev/null || return 1
	_record_for new.md | jq -e --arg s "$BYSTANDER" '.session_id == $s' >/dev/null
}

@test "without duration_ms the hook attributes as it always has" {
	# No timing means no lower bound on the command's start, so there is
	# nothing to compare an mtime against. Keep today's behavior rather than
	# guess in either direction.
	_bash "$BYSTANDER" "echo seed"
	printf 'ghost\n' > "${REPO}/runbook.md"
	_age runbook.md 60
	_bash "$BYSTANDER" "ls"

	_record_for runbook.md | jq -e --arg s "$BYSTANDER" \
		'.session_id == $s and (has("authorship") | not)' >/dev/null
}

@test "the clock slack is configurable" {
	# Raise the slack past the file's age and the same change is attributable
	# again: the bound is "started at least this long before the write".
	mkdir -p "${REPO}/.claude"
	printf '%s' '{"lineage":{"attribution_slack_seconds":600}}' > "${REPO}/.claude/settings.json"
	git -C "$REPO" add .claude/settings.json
	git -C "$REPO" commit -qm settings

	_bash "$BYSTANDER" "echo seed" 40
	printf 'ghost\n' > "${REPO}/runbook.md"
	_age runbook.md 60
	_bash "$BYSTANDER" "ls" 40

	_record_for runbook.md | jq -e --arg s "$BYSTANDER" '.session_id == $s' >/dev/null
}

# --- /lineage rendering (acceptance 3) ----------------------------------------

@test "an unknown record renders as unknown and names no session" {
	local rec
	rec=$(jq -cn '{tool: "Bash", authorship: "unknown", authorship_reason: "predates_call",
		observed_by_session_id: "sess-bystander"}')
	run lineage_author_phrase "$rec"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"unknown"* ]] || return 1
	[[ "$output" != *"sess-bystander"* ]]
}

@test "an attributed record renders its session" {
	run lineage_author_phrase '{"tool":"Edit","session_id":"sess-author"}'
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "session sess-author" ]
}

@test "the authorship note explains predates_call, and is empty for an attributed record" {
	run lineage_authorship_note '{"authorship":"unknown","authorship_reason":"predates_call"}'
	[[ "$output" == *"before"*"started"* ]] || return 1
	run lineage_authorship_note '{"session_id":"sess-author"}'
	[ -z "$output" ]
}

@test "an unknown record resolves no prompt, even with history on disk for the observer" {
	# Historian holds a chunk for the observer. An unknown record must not
	# reach it: that prompt is the wrong answer this whole change removes.
	local hist="${ONLOOKER_DIR}/historian/${KEY}/sessions"
	mkdir -p "$hist"
	jq -cn '{start_turn_index: 0, end_turn_index: 9, body_redacted: "the observer prompt"}' \
		> "${hist}/sess-bystander.jsonl"

	run lineage_resolve_record_prompt "$KEY" \
		'{"authorship":"unknown","authorship_reason":"predates_call","observed_by_session_id":"sess-bystander"}'
	[ "$status" -eq 0 ] || return 1
	printf '%s' "$output" | jq -e '.prompt == "" and .resolved_via == "none"' >/dev/null || return 1

	# Control: the same history does resolve for an attributed record.
	run lineage_resolve_record_prompt "$KEY" '{"session_id":"sess-bystander","turn":1}'
	printf '%s' "$output" | jq -e '.resolved_via == "historian"' >/dev/null
}

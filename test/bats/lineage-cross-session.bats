#!/usr/bin/env bats

# Two sessions, one checkout (ecosystem-449.41).
#
# The Bash branch detects shell-shaped edits by diffing the working tree
# against a rolling baseline (ecosystem-449.13). That baseline was keyed per
# (worktree scope, SESSION) while the tree it describes is shared, so a second
# session's baseline went stale the moment any other session touched the repo.
# Its next Bash PostToolUse — for any command at all, including a pure read —
# then saw the other session's work as new and unattributed, and recorded it
# under its own session_id.
#
# In the field that produced five ghost records in 80 seconds, and made
# /lineage answer "who wrote this line" with the wrong session and that
# session's prompt. A wrong answer is worse here than no answer: the plugin
# exists to be trusted about exactly this.
#
# ORDERING IS THE WHOLE TEST. A session's first Bash call seeds its baseline
# and deliberately records nothing, so a bystander that arrives AFTER the work
# is already safe today. The bug needs the bystander to have seeded BEFORE the
# change — which is the ordinary case, since sessions run shell commands from
# their first turn. Every test here seeds the bystander first for that reason;
# written the other way round they pass against the broken code.
#
# The existing I3 concurrency test in lineage-shell-edit.bats runs four hooks
# at once, but all four carry ONE session id, so they share a baseline and its
# lock. Nothing in the suite crossed sessions until this file.

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
	source "${PLUGIN_ROOT}/scripts/lib/lineage-project-key.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-record.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-baseline.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-query.sh"

	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name "Test"
	git -C "$REPO" config status.showUntrackedFiles normal
	git -C "$REPO" remote add origin git@github.com:org/fixture.git
	printf 'one\n' > "${REPO}/tracked.txt"
	git -C "$REPO" add tracked.txt
	git -C "$REPO" commit -qm seed

	KEY=$(lineage_project_key "$REPO")
	LEDGER="${ONLOOKER_DIR}/lineage/${KEY}/changes.jsonl"
	REPO_REAL=$(cd "$REPO" && pwd -P)
	SCOPE_ID=$(lineage_baseline_scope_id "$(lineage_project_repo_root "$REPO")")
	BASELINE_DIR=$(lineage_baseline_dir "$SCOPE_ID")

	AUTHOR="sess-author"
	BYSTANDER="sess-bystander"
}

# _bash <session> <command>
_bash() {
	jq -cn --arg cwd "$REPO" --arg sid "$1" --arg cmd "$2" \
		'{cwd: $cwd, session_id: $sid, tool_name: "Bash",
		  tool_input: {command: $cmd}, hook_event_name: "PostToolUse"}' \
		> "${BATS_TEST_TMPDIR}/in.json"
	bash "$HOOK" < "${BATS_TEST_TMPDIR}/in.json"
}

# _edit <session> <relative-path> <new-content>
#
# PostToolUse fires after the tool already wrote, so the disk write comes
# first and the hook is told about it — the hook itself never edits.
_edit() {
	printf '%s\n' "$3" > "${REPO}/$2"
	jq -cn --arg cwd "$REPO" --arg sid "$1" --arg f "${REPO}/$2" --arg new "$3" \
		'{session_id: $sid, cwd: $cwd, tool_name: "Edit", tool_use_id: "toolu_x",
		  transcript_path: "", tool_input: {file_path: $f, old_string: "one", new_string: $new}}' \
		> "${BATS_TEST_TMPDIR}/in.json"
	bash "$HOOK" < "${BATS_TEST_TMPDIR}/in.json"
}

_records_for() {
	[ -f "$LEDGER" ] || { printf '0'; return 0; }
	local n
	n=$(jq -rs --arg s "$1" '[.[] | select(.session_id == $s)] | length' "$LEDGER" 2>/dev/null) || n=0
	printf '%s' "$n"
}

_total_records() {
	[ -f "$LEDGER" ] || { printf '0'; return 0; }
	wc -l < "$LEDGER" | tr -d ' '
}

@test "a bystander's read-only Bash call does not record the author's Edit" {
	# The exact field sequence: a session that has been running a while, then
	# someone else's edit, then a command that writes nothing at all. Every
	# ghost record in the field came from commands like this one — bd show,
	# grep, node -e.
	_bash "$BYSTANDER" "echo seed"
	_edit "$AUTHOR" tracked.txt "edited by the author"
	_bash "$BYSTANDER" "grep -r nothing ."

	[ "$(_records_for "$BYSTANDER")" -eq 0 ] || return 1
	[ "$(_records_for "$AUTHOR")" -eq 1 ]
}

@test "a bystander does not duplicate the author's shell edit" {
	# Same shape, but the change arrives through the shell, so the author's
	# own Bash hook is what records it. In the field this is where duplicates
	# piled up — one per bystander Bash call, for as long as the change stayed
	# uncommitted.
	_bash "$BYSTANDER" "echo seed"
	_bash "$AUTHOR" "echo seed"
	printf 'two\n' >> "${REPO}/tracked.txt"
	_bash "$AUTHOR" "cat >> tracked.txt <<EOF"
	[ "$(_records_for "$AUTHOR")" -eq 1 ] || return 1

	_bash "$BYSTANDER" "ls"
	_bash "$BYSTANDER" "ls"
	[ "$(_records_for "$BYSTANDER")" -eq 0 ] || return 1
	[ "$(_total_records)" -eq 1 ]
}

@test "a bystander does not report a whole batch of someone else's files" {
	# The +194/-0 ghost: three files recorded under the wrong session in one
	# second, because the bystander's stale baseline made the entire pending
	# diff look like new work its own command had just done.
	_bash "$BYSTANDER" "echo seed"
	_bash "$AUTHOR" "echo seed"
	printf 'two\n' >> "${REPO}/tracked.txt"
	printf 'brand new\n' > "${REPO}/untracked.txt"
	printf 'also new\n' > "${REPO}/third.txt"
	_bash "$AUTHOR" "cat >> tracked.txt <<EOF"
	local after_author
	after_author=$(_total_records)

	_bash "$BYSTANDER" "wc -l tracked.txt"
	[ "$(_records_for "$BYSTANDER")" -eq 0 ] || return 1
	[ "$(_total_records)" -eq "$after_author" ]
}

@test "the line lookup returns the session that actually wrote the line" {
	# The user-visible failure. lineage_match_line is newest-wins, so a ghost
	# record — being newer than the true one — is what /lineage renders, and
	# the prompt it then resolves belongs to the wrong session entirely.
	_bash "$BYSTANDER" "echo seed"
	_bash "$AUTHOR" "echo seed"
	printf 'DISTINCTIVE MARKER LINE\n' >> "${REPO}/tracked.txt"
	_bash "$AUTHOR" "cat >> tracked.txt <<EOF"
	_bash "$BYSTANDER" "wc -l tracked.txt"

	local rec
	rec=$(lineage_match_line "$KEY" "${REPO_REAL}/tracked.txt" "DISTINCTIVE MARKER LINE")
	[ -n "$rec" ] || return 1
	[ "$(jq -r '.session_id' <<<"$rec")" = "$AUTHOR" ]
}

@test "sessions sharing a checkout share one baseline" {
	# The mechanism, asserted directly. A per-session baseline cannot answer
	# "did MY command change this" about a tree it does not exclusively own,
	# so the fix is that the baseline describes the checkout, not the session.
	_bash "$AUTHOR" "echo seed"
	_bash "$BYSTANDER" "echo seed"

	local count
	count=$(find "$BASELINE_DIR" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
	[ "$count" -eq 1 ]
}

@test "a genuine shell edit is still recorded, with its own session (449.13)" {
	# The inverse guard. The rolling baseline exists because lineage saw tool
	# calls rather than file changes and missed every shell-shaped edit. A fix
	# that quiets the Bash branch to stop the ghosts would put that back.
	_bash "$AUTHOR" "echo seed"
	printf 'shell wrote this\n' >> "${REPO}/tracked.txt"
	_bash "$AUTHOR" "printf 'shell wrote this\\n' >> tracked.txt"

	[ "$(_records_for "$AUTHOR")" -eq 1 ] || return 1
	run jq -rs '.[0] | "\(.tool) \(.operation)"' "$LEDGER"
	[ "$output" = "Bash shell_edit" ]
}

@test "each session's own shell edits are still attributed to it" {
	# Two authors, two changes, two correct attributions — so the fix cannot
	# become "only the session that seeded ever records anything".
	_bash "$AUTHOR" "echo seed"
	_bash "$BYSTANDER" "echo seed"

	printf 'from the author\n' >> "${REPO}/tracked.txt"
	_bash "$AUTHOR" "printf 'from the author\\n' >> tracked.txt"
	printf 'from the other session\n' > "${REPO}/second.txt"
	_bash "$BYSTANDER" "printf 'from the other session\\n' > second.txt"

	[ "$(_records_for "$AUTHOR")" -eq 1 ] || return 1
	[ "$(_records_for "$BYSTANDER")" -eq 1 ]
}

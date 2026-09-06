#!/usr/bin/env bats

# Worktree provenance (ecosystem-449.33).
#
# lineage_project_repo_root resolves through --git-common-dir and returns the
# MAIN checkout's toplevel, deliberately, so a worktree shares its parent's
# project key. The bug was every downstream use of that value as if it were the
# tree the session is working in: the Edit path used it as a containment
# boundary, and the Bash path used it as the diff target. Both silently produced
# nothing for worktree work, and the Bash path recorded the parent checkout's
# changes against the worktree's session.
#
# These drive a real `git worktree add` rather than a simulated path shape,
# because the defect is in what git reports about a real linked worktree.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/lineage"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/lineage-post-tool-use.sh"
	export _ONLOOKER_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")" "${ONLOOKER_DIR}/session-trackers"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/lineage-project-key.sh"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "$MAIN"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email t@example.com
	git -C "$MAIN" config user.name "Test"
	git -C "$MAIN" config status.showUntrackedFiles normal
	git -C "$MAIN" remote add origin git@github.com:org/fixture.git
	printf 'one\n' > "${MAIN}/tracked.txt"
	git -C "$MAIN" add tracked.txt
	git -C "$MAIN" commit -qm seed

	# A real linked worktree: .git is a file, and --git-common-dir points back
	# at the main checkout's .git.
	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch

	# Both spellings realpath-resolved, since the hook resolves every recorded
	# path and a symlinked tmpdir (macOS /var -> /private/var) diverges.
	MAIN_REAL=$(cd "$MAIN" && pwd -P)
	WT_REAL=$(cd "$WT" && pwd -P)

	KEY=$(lineage_project_key "$WT")
	LEDGER="${ONLOOKER_DIR}/lineage/${KEY}/changes.jsonl"
	SID="bats-wt-001"
}

# _edit <cwd> <file_path>
_edit() {
	jq -nc --arg sid "$SID" --arg cwd "$1" --arg f "$2" \
		'{session_id:$sid, cwd:$cwd, tool_name:"Edit", tool_use_id:"toolu_wt",
		  transcript_path:"", tool_input:{file_path:$f, old_string:"one", new_string:"two"}}' \
		| bash "$HOOK"
}

# _bash <cwd> <command>
_bash() {
	jq -nc --arg sid "$SID" --arg cwd "$1" --arg cmd "$2" \
		'{session_id:$sid, cwd:$cwd, tool_name:"Bash", tool_use_id:"toolu_wtb",
		  transcript_path:"", hook_event_name:"PostToolUse", tool_input:{command:$cmd}}' \
		| bash "$HOOK"
}

@test "a worktree and its parent resolve to the same project key" {
	# The fix must not change storage partitioning: worktree provenance belongs
	# in the same ledger as the repo it branched from.
	[ "$(lineage_project_key "$WT")" = "$(lineage_project_key "$MAIN")" ]
}

@test "records an Edit made inside a git worktree" {
	printf 'two\n' > "${WT}/tracked.txt"
	_edit "$WT" "${WT}/tracked.txt"
	[ -f "$LEDGER" ] || return 1
	[ "$(jq -rs '.[0].file_path' "$LEDGER")" = "${WT_REAL}/tracked.txt" ]
}

@test "records a shell edit made inside a git worktree" {
	_bash "$WT" "echo seed"
	printf 'two\n' >> "${WT}/tracked.txt"
	_bash "$WT" "cat >> tracked.txt <<EOF"
	[ -f "$LEDGER" ] || return 1
	run jq -rs '[.[] | select(.tool == "Bash") | .file_path] | join(",")' "$LEDGER"
	[[ "$output" == *"${WT_REAL}/tracked.txt"* ]]
}

@test "a worktree session does not record the parent checkout's changes" {
	# The sharpest half of 449.33: missing data is one failure, but recording
	# another tree's change against this session is a worse one, because
	# /lineage cannot tell the two apart.
	_bash "$WT" "echo seed"
	printf 'edited in the parent checkout\n' >> "${MAIN}/tracked.txt"
	_bash "$WT" "cat >> tracked.txt <<EOF"
	if [ -f "$LEDGER" ]; then
		run jq -rs '[.[] | .file_path] | join(",")' "$LEDGER"
		[[ "$output" != *"${MAIN_REAL}/tracked.txt"* ]] || return 1
	fi
	[ 1 -eq 1 ]
}

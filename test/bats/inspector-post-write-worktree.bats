#!/usr/bin/env bats

# Inspector's REPO_ROOT in a linked worktree (ecosystem-449.33 / 449.37
# reintroduced).
#
# inspector-post-write.sh derived REPO_ROOT from onlooker_project_repo_root,
# which deliberately resolves a linked worktree to its PARENT checkout, so a
# worktree and its parent share one project key. That is the right answer for
# IDENTITY and the wrong one for every use REPO_ROOT actually gets in this
# hook: the containment check, the relative-path strip, and everything
# downstream of them are about LOCATION — the tree this session is in, not
# the tree it would share a key with.
#
# A worktree's files sit beside its parent, not beneath it, so a file edited
# inside the worktree does not start with the parent's path. Every edit then
# failed the containment check and reported not_in_repo, and inspector
# silently did nothing for the entire session.
#
# This drives a real `git worktree add` rather than a simulated path shape,
# because the defect is in what git reports about a real linked worktree.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	# These tests assert on the event log, so they require a schema that
	# accepts inspector.* events. Skip when the installed package is too old.
	if ! grep -q "inspector.check.passed" \
		"${BATS_TEST_DIRNAME}/../../node_modules/@onlooker-community/schema/schemas/event.v1.json" 2>/dev/null; then
		skip "installed @onlooker-community/schema has no inspector.* types yet"
	fi

	PLUGIN_ROOT="${REPO_ROOT}/plugins/inspector"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/inspector-post-write.sh"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "${MAIN}/src"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email t@example.com
	git -C "$MAIN" config user.name "Test"
	git -C "$MAIN" remote add origin git@github.com:org/fixture.git
	printf 'sample\n' >"${MAIN}/src/sample.ts"
	git -C "$MAIN" add src/sample.ts
	git -C "$MAIN" commit -qm seed

	# A real linked worktree: .git is a file, and --git-common-dir points back
	# at the main checkout's .git.
	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch

	mkdir -p "${WT}/.claude" "${WT}/src"
	printf 'sample\n' >"${WT}/src/sample.ts"
	printf '%s\n' '{"inspector":{"checks":{".ts":[{"name":"t","kind":"lint","argv":["true"]}]}}}' \
		>"${WT}/.claude/settings.json"
}

_event_count() {
	local et="$1"
	if [[ -f "$ONLOOKER_EVENTS_LOG" ]]; then
		jq -c "select(.event_type == \"$et\")" "$ONLOOKER_EVENTS_LOG" | wc -l | tr -d ' '
	else
		printf '0'
	fi
}

_input() {
	jq -n --arg cwd "$1" --arg p "$2" \
		'{cwd:$cwd, session_id:"bats-wt-inspector", tool_name:"Edit", tool_input:{file_path:$p}}'
}

_run_hook() {
	printf '%s' "$1" | ONLOOKER_DIR="$ONLOOKER_DIR" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$HOOK"
}

@test "an edit inside a linked worktree is not reported not_in_repo" {
	run _run_hook "$(_input "$WT" "${WT}/src/sample.ts")"
	[ "$status" -eq 0 ] || return 1

	if [[ "$(_event_count inspector.check.skipped)" != "0" ]]; then
		echo "unexpected skip reason: $(jq -r 'select(.event_type=="inspector.check.skipped").payload.reason' "$ONLOOKER_EVENTS_LOG")" >&2
		return 1
	fi
	[ "$(_event_count inspector.run.completed)" = "1" ]
}

@test "REPO_ROOT strips the worktree's own prefix, not the parent's" {
	run _run_hook "$(_input "$WT" "${WT}/src/sample.ts")"
	[ "$status" -eq 0 ] || return 1

	# A relative path of "src/sample.ts" only comes out of the containment
	# check and strip in inspector-post-write.sh:92-97 when REPO_ROOT equals
	# the worktree's own root. Had REPO_ROOT resolved to the parent checkout
	# instead, this file would never reach a relative strip at all — it would
	# be reported not_in_repo before INSPECTOR_FILE_RELATIVE is ever set this
	# way.
	jq -e --arg rel "src/sample.ts" \
		'select(.event_type == "inspector.run.completed")
		 | .payload.file_path_relative == $rel' \
		"$ONLOOKER_EVENTS_LOG" >/dev/null
}

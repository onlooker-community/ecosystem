#!/usr/bin/env bats
# Cartographer's REPO_ROOT in a linked worktree (ecosystem-449.33 / 449.37
# reintroduced).
#
# cartographer-session-start.sh derived REPO_ROOT from
# onlooker_project_repo_root, which deliberately resolves a linked worktree to
# its PARENT checkout, so a worktree and its parent share one project key.
# That is the right answer for IDENTITY and the wrong one for the two uses
# REPO_ROOT gets here, both of them LOCATION: onlooker_watch_unmatched_check's
# --root (this file) and the root run-audit.sh hands to the matcher
# (cartographer-post-write.sh exports the same value under
# CARTOGRAPHER_REPO_ROOT). In a worktree, that silently scanned and audited
# the parent checkout's files instead of the worktree's.
#
# Proven through onlooker_watch_unmatched_check rather than a full audit run:
# it is synchronous and needs no background process or stubbed `claude`. A
# glob that matches only inside the PARENT checkout must be reported
# unmatched when the session's cwd is the WORKTREE — if REPO_ROOT had
# resolved to the parent instead, the same glob would match there and the
# hook would stay quiet.
#
# This drives a real `git worktree add` rather than a simulated path shape,
# because the defect is in what git reports about a real linked worktree.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/cartographer"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"
	HOOK="${PLUGIN_ROOT}/scripts/hooks/cartographer-session-start.sh"

	MAIN="${BATS_TEST_TMPDIR}/main"
	mkdir -p "${MAIN}/.claude" "${MAIN}/mainonly/child"
	git -C "$MAIN" init -q
	git -C "$MAIN" config user.email test@example.com
	git -C "$MAIN" config user.name test
	git -C "$MAIN" remote add origin git@github.com:org/fixture.git
	printf '# Root\n' >"${MAIN}/CLAUDE.md"
	git -C "$MAIN" add -A
	git -C "$MAIN" commit -qm init

	# A real linked worktree: .git is a file, and --git-common-dir points back
	# at the main checkout's .git. "mainonly/" exists only in the main
	# checkout — a worktree's files sit beside it, not beneath it.
	WT="${BATS_TEST_TMPDIR}/wt"
	git -C "$MAIN" worktree add -q "$WT" -b wt-branch

	mkdir -p "${WT}/.claude"
	printf '%s\n' '{"cartographer":{"undocumented_entity":{"globs":["mainonly/*/"]}}}' \
		>"${WT}/.claude/settings.json"

	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
	PROJECT_KEY=$(onlooker_project_key "$WT")
	mkdir -p "${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}"
	# Interval gate must not spawn an audit for this test — the watch check
	# runs before it regardless (ecosystem-449.21), mirroring
	# cartographer-session-start.bats.
	date +%s >"${ONLOOKER_DIR}/cartographer/${PROJECT_KEY}/last_audit_at"
}

_run_hook() {
	run bash -c "printf '%s' '$(jq -cn --arg cwd "$WT" \
		'{cwd: $cwd, session_id: "sess-carto-wt", hook_event_name: "SessionStart", source: "startup"}')' | '$HOOK'"
}

@test "a glob matching only inside the parent checkout is unmatched from the worktree" {
	_run_hook
	[ "$status" -eq 0 ] || return 1

	# If REPO_ROOT had resolved to the parent checkout (the identity/location
	# bug), "mainonly" would exist there and the glob would match — no event.
	# Resolved to the worktree itself, which has no "mainonly" directory of
	# its own, the glob matches nothing and the hook reports it.
	grep '"event_type":"onlooker.watch.unmatched"' "$ONLOOKER_EVENTS_LOG" \
		| jq -e '.payload.plugin == "cartographer"
		         and .payload.patterns == ["mainonly/*/"]' >/dev/null
}

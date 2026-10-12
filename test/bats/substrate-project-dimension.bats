#!/usr/bin/env bats
#
# The project dimension on SUBSTRATE events (ONL-129).
#
# This is the 79% the feature exists for. Before this, a project key existed
# only inside `payload`, only for five plugins, and payloads deliberately never
# cross to the hosted side — so all of session.*, tool.*, skill.invoked and
# task.* were unattributable to a repository.
#
# The resolve happens at the shared emit chokepoints, not in each hook: four
# trackers build their record through onlooker_event_from_hook, so one call
# there covers them and any hook added later. Resolving per-hook instead is the
# shape that produced thirteen drifting project-key libs and fourteen wrong
# substrate lookups, both of which failed silently.

# `run --separate-stderr` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	load_validate_path
	# shellcheck source=../../scripts/lib/onlooker-project-key.sh
	source "${REPO_ROOT}/scripts/lib/onlooker-project-key.sh"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git

	CACHE_FILE="${ONLOOKER_DIR}/project-key-cache.tsv"
	: >"$ONLOOKER_EVENTS_LOG"
}

_run_hook() {
	local hook="$1" input="$2"
	printf '%s' "$input" | "${REPO_ROOT}/scripts/hooks/${hook}" >/dev/null 2>&1 || true
}

_tool_input() {
	jq -cn --arg cwd "$PROJECT_REPO" \
		'{cwd: $cwd, session_id: "substrate-sess", hook_event_name: "PostToolUse",
		  tool_name: "Read", tool_input: {file_path: "/tmp/x"}}'
}

@test "a tool.* event carries the project dimension" {
	_run_hook "tool-history-tracker.sh" "$(_tool_input)"

	local line
	line=$(grep '"event_type":"tool.file.read"' "$ONLOOKER_EVENTS_LOG" | tail -n 1)
	[ -n "$line" ] || return 1

	onlooker_project_resolve "$PROJECT_REPO"
	printf '%s' "$line" | jq -e --arg k "$ONLOOKER_PROJECT_KEY" '.project == $k' >/dev/null || return 1
	printf '%s' "$line" | jq -e '.project_basis == "remote"' >/dev/null
}

@test "a session.* event carries the project dimension" {
	local input
	input=$(jq -cn --arg cwd "$PROJECT_REPO" \
		'{cwd: $cwd, session_id: "substrate-sess", hook_event_name: "SessionStart",
		  source: "startup"}')
	_run_hook "session-start-tracker.sh" "$input"

	local line
	line=$(grep '"event_type":"session.start"' "$ONLOOKER_EVENTS_LOG" | tail -n 1)
	[ -n "$line" ] || return 1

	onlooker_project_resolve "$PROJECT_REPO"
	printf '%s' "$line" | jq -e --arg k "$ONLOOKER_PROJECT_KEY" '.project == $k' >/dev/null || return 1
	printf '%s' "$line" | jq -e '.project_basis == "remote"' >/dev/null
}

@test "the emitted key matches the directory plugins already partition by" {
	# The join ONL-9 exists to enable. If these two ever diverge, a per-repo
	# view silently double-counts and nothing on the wire says so.
	_run_hook "tool-history-tracker.sh" "$(_tool_input)"

	onlooker_project_resolve "$PROJECT_REPO"
	local artifact_dir="${ONLOOKER_DIR}/librarian/${ONLOOKER_PROJECT_KEY}"
	mkdir -p "$artifact_dir"

	local emitted
	emitted=$(grep '"event_type":"tool.file.read"' "$ONLOOKER_EVENTS_LOG" | tail -n 1 | jq -r '.project')
	[ "$emitted" = "$(basename "$artifact_dir")" ]
}

@test "a hook whose cwd is not a repo emits no project fields" {
	local not_a_repo="${BATS_TEST_TMPDIR}/plain"
	mkdir -p "$not_a_repo"
	local input
	input=$(jq -cn --arg cwd "$not_a_repo" \
		'{cwd: $cwd, session_id: "s2", hook_event_name: "PostToolUse",
		  tool_name: "Read", tool_input: {file_path: "/tmp/x"}}')
	_run_hook "tool-history-tracker.sh" "$input"

	local line
	line=$(grep '"event_type":"tool.file.read"' "$ONLOOKER_EVENTS_LOG" | tail -n 1)
	[ -n "$line" ] || return 1
	printf '%s' "$line" | jq -e 'has("project") == false' >/dev/null || return 1
	printf '%s' "$line" | jq -e 'has("project_basis") == false' >/dev/null
}

@test "the hook payload's cwd wins over the process's own directory" {
	# A hook process is not guaranteed to run in the session's directory, which
	# is why Claude Code puts cwd on the wire. Run the hook FROM the non-repo so
	# $(pwd) would give the wrong answer, and point its payload at the repo.
	local elsewhere="${BATS_TEST_TMPDIR}/elsewhere"
	mkdir -p "$elsewhere"

	printf '%s' "$(_tool_input)" | \
		(cd "$elsewhere" && "${REPO_ROOT}/scripts/hooks/tool-history-tracker.sh") >/dev/null 2>&1 || true

	onlooker_project_resolve "$PROJECT_REPO"
	grep '"event_type":"tool.file.read"' "$ONLOOKER_EVENTS_LOG" | tail -n 1 \
		| jq -e --arg k "$ONLOOKER_PROJECT_KEY" '.project == $k' >/dev/null
}

@test "resolving writes one cache line and reuses it across hook runs" {
	_run_hook "tool-history-tracker.sh" "$(_tool_input)"
	_run_hook "tool-history-tracker.sh" "$(_tool_input)"
	_run_hook "tool-history-tracker.sh" "$(_tool_input)"

	[ -f "$CACHE_FILE" ] || return 1
	# Three hook runs, three separate processes, one line. More than one means
	# the disk tier is not being read and every event pays for git.
	[ "$(wc -l <"$CACHE_FILE" | tr -d ' ')" = "1" ]
}

@test "the on-disk cache is what a separate process actually reads" {
	# Proves the DISK tier rather than the in-shell memo: seed a sentinel for
	# this cwd, then resolve in a fresh bash. A resolver ignoring the cache
	# would return the real key instead.
	printf '%s\t%s\t%s\n' "$PROJECT_REPO" "aaaaaaaaaaaa" "root" >"$CACHE_FILE"

	run bash -c "source '${REPO_ROOT}/scripts/lib/onlooker-project-key.sh'
		onlooker_project_resolve_cached '$PROJECT_REPO'
		printf '%s %s' \"\$ONLOOKER_PROJECT_KEY\" \"\$ONLOOKER_PROJECT_BASIS\""
	[ "$output" = "aaaaaaaaaaaa root" ]
}

@test "ONLOOKER_PROJECT_CACHE=0 bypasses both tiers" {
	printf '%s\t%s\t%s\n' "$PROJECT_REPO" "aaaaaaaaaaaa" "root" >"$CACHE_FILE"

	onlooker_project_resolve "$PROJECT_REPO"
	local real_key="$ONLOOKER_PROJECT_KEY"

	run bash -c "source '${REPO_ROOT}/scripts/lib/onlooker-project-key.sh'
		ONLOOKER_PROJECT_CACHE=0 onlooker_project_resolve_cached '$PROJECT_REPO'
		printf '%s' \"\$ONLOOKER_PROJECT_KEY\""
	[ "$output" = "$real_key" ] || return 1
	[ "$output" != "aaaaaaaaaaaa" ]
}

@test "a non-repo cwd caches its negative result" {
	# Two FAILING git calls is what discovering a non-repo costs, and $HOME is a
	# cwd hooks genuinely see. Caching the negative is the point.
	local not_a_repo="${BATS_TEST_TMPDIR}/plain2"
	mkdir -p "$not_a_repo"

	onlooker_project_resolve_cached "$not_a_repo"
	[ -z "$ONLOOKER_PROJECT_KEY" ] || return 1

	grep -q "^${not_a_repo}	" "$CACHE_FILE" || return 1
	# And the cached negative reads back as empty, not as the literal string.
	run bash -c "source '${REPO_ROOT}/scripts/lib/onlooker-project-key.sh'
		onlooker_project_resolve_cached '$not_a_repo'
		printf '[%s][%s]' \"\$ONLOOKER_PROJECT_KEY\" \"\$ONLOOKER_PROJECT_BASIS\""
	[ "$output" = "[][]" ]
}

@test "a cwd containing a tab is resolved but never cached" {
	# A tab in the path would write a line that reads back as the wrong fields,
	# which would hand some other directory this one's key. Skip the cache
	# rather than poison it.
	local tabbed="${BATS_TEST_TMPDIR}/has"$'\t'"tab"
	mkdir -p "$tabbed"
	git -C "$tabbed" init -q
	git -C "$tabbed" remote add origin git@github.com:org/tabbed.git

	onlooker_project_resolve_cached "$tabbed"
	[ -n "$ONLOOKER_PROJECT_KEY" ] || return 1
	[ "$ONLOOKER_PROJECT_BASIS" = "remote" ] || return 1

	if [ -f "$CACHE_FILE" ]; then
		! grep -q "has	tab" "$CACHE_FILE" || return 1
	fi
	[ -n "$ONLOOKER_PROJECT_KEY" ]
}

@test "an unwritable cache still resolves and still emits" {
	# Caching is an optimization and must never be able to fail the emission it
	# exists to speed up. The hazard is specific: onlooker-emit.sh runs under
	# `set -euo pipefail`, and the cache's printf sits in the one position
	# errexit does not exempt — after the final `&&` — so without the `|| true`
	# an unwritable cache aborts the caller and the event is simply lost.
	#
	# Driven through a `set -e` shell on purpose, because that is the only shell
	# where the bug reproduces; under the test's own bash it would pass either
	# way and assert nothing.
	printf 'x' >"$CACHE_FILE"
	chmod 400 "$CACHE_FILE"

	# --separate-stderr so $output is stdout alone. It also lets the second
	# assertion stand: an unwritable cache must stay SILENT, because a shell
	# redirection failure is reported by the shell and would otherwise print
	# "Permission denied" into the session on every single event.
	run --separate-stderr bash -c "set -euo pipefail
		source '${REPO_ROOT}/scripts/lib/onlooker-project-key.sh'
		onlooker_project_resolve_cached '$PROJECT_REPO'
		printf 'SURVIVED:%s' \"\$ONLOOKER_PROJECT_KEY\""

	chmod 600 "$CACHE_FILE"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == SURVIVED:* ]] || return 1
	[ "$output" != "SURVIVED:" ] || return 1
	[ -z "$stderr" ]
}

@test "a runaway cache is bounded rather than scanned forever" {
	# The scan is linear and the inputs are not: every throwaway directory a
	# hook runs in earns a negative line that is never reused. Measured, a
	# 500-line cache costs ~7ms to scan, closing on the ~22ms git call the
	# cache exists to avoid. Past the cap the file starts over.
	local i
	for ((i = 0; i < 300; i++)); do
		printf '/nowhere/dir%d\t%012d\troot\n' "$i" "$i" >>"$CACHE_FILE"
	done
	[ "$(wc -l <"$CACHE_FILE" | tr -d ' ')" = "300" ] || return 1

	onlooker_project_resolve_cached "$PROJECT_REPO"

	# One line: this cwd's. The 300 stale ones are gone, not appended to.
	[ "$(wc -l <"$CACHE_FILE" | tr -d ' ')" = "1" ] || return 1
	grep -q "^${PROJECT_REPO}	" "$CACHE_FILE" || return 1
	# And the resolve itself still produced a usable answer.
	[ -n "$ONLOOKER_PROJECT_KEY" ]
}

@test "a cache under the cap keeps its existing entries" {
	# The bound must not evict on every write — that would make the cache a
	# single-entry one and send every other project back to git each time.
	printf '/nowhere/other\tbbbbbbbbbbbb\troot\n' >"$CACHE_FILE"

	onlooker_project_resolve_cached "$PROJECT_REPO"

	[ "$(wc -l <"$CACHE_FILE" | tr -d ' ')" = "2" ] || return 1
	grep -q "^/nowhere/other	" "$CACHE_FILE"
}

@test "a second cwd gets its own key rather than the first one's" {
	# The memo is keyed on cwd. Keyed on anything coarser, a hook emitting for
	# two directories would attribute both to whichever resolved first.
	local other="${BATS_TEST_TMPDIR}/other"
	mkdir -p "$other"
	git -C "$other" init -q
	git -C "$other" remote add origin git@github.com:org/other.git

	onlooker_project_resolve_cached "$PROJECT_REPO"
	local first="$ONLOOKER_PROJECT_KEY"
	onlooker_project_resolve_cached "$other"
	local second="$ONLOOKER_PROJECT_KEY"

	[ -n "$first" ] || return 1
	[ -n "$second" ] || return 1
	[ "$first" != "$second" ]
}

#!/usr/bin/env bats

# tribunal-resolve.sh: the baseline a /tribunal run takes when it starts, the
# discard offered when the jury does not accept the result, and the
# tribunal.session.resolved payload (ONL-308). The rule every discard test
# protects: a file that was dirty before the run is never touched.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	# shellcheck source=../../plugins/tribunal/scripts/lib/tribunal-resolve.sh
	source "${REPO_ROOT}/plugins/tribunal/scripts/lib/tribunal-resolve.sh"

	# Keeps git from finding a repository above the scratch directory, so the
	# outside-git case is outside git wherever the suite runs.
	export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"

	REPO="${BATS_TEST_TMPDIR}/repo"
	TASK="${BATS_TEST_TMPDIR}/task"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email test@example.com
	git -C "$REPO" config user.name test
	printf 'a\n' > "$REPO/a.txt"
	printf 'b\n' > "$REPO/b.txt"
	git -C "$REPO" add a.txt b.txt
	git -C "$REPO" commit -q -m init
}

@test "baseline fails outside a git worktree and writes nothing" {
	mkdir -p "${BATS_TEST_TMPDIR}/plain"
	run tribunal_baseline_write "$TASK" "${BATS_TEST_TMPDIR}/plain"
	[ "$status" -eq 1 ] || return 1
	[ ! -e "$TASK/baseline.json" ]
}

@test "baseline fails before the first commit and writes nothing" {
	mkdir -p "${BATS_TEST_TMPDIR}/fresh"
	git -C "${BATS_TEST_TMPDIR}/fresh" init -q
	run tribunal_baseline_write "$TASK" "${BATS_TEST_TMPDIR}/fresh"
	[ "$status" -eq 1 ] || return 1
	[ ! -e "$TASK/baseline.json" ]
}

@test "baseline records the root, HEAD, and each dirty path with its hash" {
	printf 'mine\n' >> "$REPO/b.txt"
	printf 'n\n' > "$REPO/notes.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	local b="$TASK/baseline.json"
	[ "$(jq -r .head "$b")" = "$(git -C "$REPO" rev-parse HEAD)" ] || return 1
	[ "$(jq -r .root "$b")" = "$(git -C "$REPO" rev-parse --show-toplevel)" ] || return 1
	[ "$(jq -r '[.dirty[].path] | sort | join(",")' "$b")" = "b.txt,notes.txt" ] || return 1
	[ "$(jq -r '.dirty[] | select(.path == "b.txt") | .hash' "$b")" = "$(git -C "$REPO" hash-object b.txt)" ]
}

@test "baseline of a clean tree lists nothing dirty" {
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	[ "$(jq '.dirty | length' "$TASK/baseline.json")" = "0" ]
}

@test "discard restores a tracked file the actor changed" {
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	printf 'actor\n' >> "$REPO/a.txt"
	run tribunal_discard "$TASK"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "1 0" ] || return 1
	[ "$(cat "$REPO/a.txt")" = "a" ]
}

@test "discard brings back a tracked file the actor deleted" {
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	rm "$REPO/a.txt"
	run tribunal_discard "$TASK"
	[ "$output" = "1 0" ] || return 1
	[ "$(cat "$REPO/a.txt")" = "a" ]
}

@test "discard deletes an untracked file the actor created" {
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	mkdir -p "$REPO/new/dir"
	printf 'x\n' > "$REPO/new/dir/x.txt"
	run tribunal_discard "$TASK"
	[ "$output" = "1 0" ] || return 1
	[ ! -e "$REPO/new/dir/x.txt" ]
}

@test "discard removes a new file the actor staged, from the index too" {
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	printf 'x\n' > "$REPO/staged.txt"
	git -C "$REPO" add staged.txt
	run tribunal_discard "$TASK"
	[ "$output" = "1 0" ] || return 1
	[ ! -e "$REPO/staged.txt" ] || return 1
	[ -z "$(git -C "$REPO" status --porcelain)" ]
}

@test "discard handles a path with a space" {
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	printf 'x\n' > "$REPO/my notes.txt"
	run tribunal_discard "$TASK"
	[ "$output" = "1 0" ] || return 1
	[ ! -e "$REPO/my notes.txt" ]
}

@test "discard leaves a file dirty before the run, and names it when the actor changed it again" {
	printf 'mine\n' >> "$REPO/b.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	printf 'actor\n' >> "$REPO/b.txt"
	printf 'actor\n' >> "$REPO/a.txt"
	run tribunal_discard "$TASK"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "$(printf '1 1\nb.txt')" ] || return 1
	[ "$(cat "$REPO/b.txt")" = "$(printf 'b\nmine\nactor')" ] || return 1
	[ "$(cat "$REPO/a.txt")" = "a" ]
}

@test "discard leaves an untracked file from before the run, and does not count it when untouched" {
	printf 'n\n' > "$REPO/notes.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	run tribunal_discard "$TASK"
	[ "$output" = "0 0" ] || return 1
	[ "$(cat "$REPO/notes.txt")" = "n" ]
}

@test "discard leaves an untracked file from before the run that the actor edited, and names it" {
	printf 'n\n' > "$REPO/notes.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	printf 'actor\n' >> "$REPO/notes.txt"
	run tribunal_discard "$TASK"
	[ "$output" = "$(printf '0 1\nnotes.txt')" ] || return 1
	[ "$(cat "$REPO/notes.txt")" = "$(printf 'n\nactor')" ]
}

@test "discard leaves a file deleted before the run deleted" {
	rm "$REPO/b.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	run tribunal_discard "$TASK"
	[ "$output" = "0 0" ] || return 1
	[ ! -e "$REPO/b.txt" ]
}

@test "discard refuses, touching nothing, when HEAD moved since the baseline" {
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	printf 'actor\n' >> "$REPO/a.txt"
	git -C "$REPO" commit -q -am "actor commit"
	printf 'actor\n' >> "$REPO/b.txt"
	run tribunal_discard "$TASK"
	[ "$status" -eq 2 ] || return 1
	[ "$(cat "$REPO/b.txt")" = "$(printf 'b\nactor')" ]
}

@test "discard fails without a baseline" {
	run tribunal_discard "$TASK"
	[ "$status" -eq 1 ]
}

# Takes a baseline with a pre-run untracked file and a pre-run edit to a
# tracked file, for the tests that must leave both byte-for-byte intact.
_prerun_work() {
	printf 'mine\n' >> "$REPO/b.txt"
	printf 'n\n' > "$REPO/notes.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
}

_prerun_work_intact() {
	[ "$(cat "$REPO/notes.txt")" = "n" ] || return 1
	[ "$(cat "$REPO/b.txt")" = "$(printf 'b\nmine')" ]
}

@test "discard fails closed on a baseline whose dirty list is not an array" {
	_prerun_work || return 1
	jq '.dirty = {}' "$TASK/baseline.json" > "$TASK/b.tmp" || return 1
	mv "$TASK/b.tmp" "$TASK/baseline.json" || return 1
	run tribunal_discard "$TASK"
	[ "$status" -eq 1 ] || return 1
	_prerun_work_intact
}

@test "discard fails closed on a baseline that is not JSON" {
	_prerun_work || return 1
	printf 'not json' > "$TASK/baseline.json"
	run tribunal_discard "$TASK"
	[ "$status" -eq 1 ] || return 1
	_prerun_work_intact
}

@test "discard fails closed on a baseline entry without a string hash" {
	_prerun_work || return 1
	jq '.dirty[0].hash = 5' "$TASK/baseline.json" > "$TASK/b.tmp" || return 1
	mv "$TASK/b.tmp" "$TASK/baseline.json" || return 1
	run tribunal_discard "$TASK"
	[ "$status" -eq 1 ] || return 1
	_prerun_work_intact
}

@test "discard names a tracked file dirty before the run that the actor reverted" {
	printf 'mine\n' >> "$REPO/b.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	git -C "$REPO" checkout -- b.txt || return 1
	run tribunal_discard "$TASK"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "$(printf '0 1\nb.txt')" ]
}

@test "discard names an untracked file from before the run that the actor deleted" {
	printf 'n\n' > "$REPO/notes.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	rm "$REPO/notes.txt"
	run tribunal_discard "$TASK"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "$(printf '0 1\nnotes.txt')" ]
}

@test "discard names a pre-run file with a space that the actor deleted" {
	printf 'n\n' > "$REPO/my notes.txt"
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	rm "$REPO/my notes.txt"
	run tribunal_discard "$TASK"
	[ "$output" = "$(printf '0 1\nmy notes.txt')" ]
}

@test "discard returns 3 and names a path it could not delete" {
	tribunal_baseline_write "$TASK" "$REPO" || return 1
	mkdir "$REPO/ro"
	printf 'x\n' > "$REPO/ro/x.txt"
	chmod 555 "$REPO/ro"
	run tribunal_discard "$TASK"
	chmod 755 "$REPO/ro"
	[ "$status" -eq 3 ] || return 1
	printf '%s\n' "$output" | grep -qF "tribunal: could not restore ro/x.txt" || return 1
	[ -e "$REPO/ro/x.txt" ]
}

@test "payload for a keep carries no counts" {
	run tribunal_resolved_payload T1 rejected kept 3 1
	[ "$status" -eq 0 ] || return 1
	[ "$output" = '{"task_id":"T1","outcome":"rejected","decision":"kept"}' ]
}

@test "payload for a retry carries no counts" {
	run tribunal_resolved_payload T1 exhausted_iterations retried
	[ "$output" = '{"task_id":"T1","outcome":"exhausted_iterations","decision":"retried"}' ]
}

@test "payload for a discard carries both counts as numbers" {
	run tribunal_resolved_payload T1 rejected discarded 3 1
	[ "$output" = '{"task_id":"T1","outcome":"rejected","decision":"discarded","files_restored":3,"files_left":1}' ]
}

@test "payload refuses an outcome the event does not resolve" {
	local o
	for o in accepted aborted bogus; do
		run tribunal_resolved_payload T1 "$o" kept
		[ "$status" -eq 1 ] || return 1
		[ -z "$output" ] || return 1
	done
}

@test "payload refuses an unknown decision" {
	run tribunal_resolved_payload T1 rejected ignored
	[ "$status" -eq 1 ]
}

@test "payload refuses an empty task id" {
	run tribunal_resolved_payload "" rejected kept
	[ "$status" -eq 1 ]
}

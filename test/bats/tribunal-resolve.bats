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

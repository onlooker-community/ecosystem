#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_DIR="${BATS_TEST_TMPDIR}/onlooker"

	source "${PLUGIN_ROOT}/scripts/lib/archivist-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"
}

# A real repository. The risk in this hook is git log parsing and the
# watermark, and a stub exercises neither.
make_repo() {
	REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$REPO"
	git -C "$REPO" init -q
	git -C "$REPO" config user.email t@example.com
	git -C "$REPO" config user.name T
	printf 'x\n' > "$REPO/a.txt"
	git -C "$REPO" add .
	git -C "$REPO" commit -q -m "$1"
	KEY=$(archivist_project_key "$REPO")
}

run_hook() {
	printf '{"cwd":"%s","session_id":"s1"}' "$REPO" |
		"${PLUGIN_ROOT}/scripts/hooks/archivist-mine.sh"
}

artifact_count() {
	find "$(archivist_project_dir "$KEY")/decisions" -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

@test "mines a commit into an artifact" {
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them on every restart."

	run run_hook
	[ "$status" -eq 0 ]
	[ "$(artifact_count)" -eq 1 ]
	run grep -l "stop dropping events" "$(archivist_project_dir "$KEY")/decisions"/*.json
	[ "$status" -eq 0 ]
}

@test "is idempotent - mining the same commit twice leaves one artifact" {
	# The content-addressed id doing its job: a second run overwrites rather
	# than accumulates, so every lesson citing that artifact keeps resolving.
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them."

	run_hook
	rm -f "$(archivist_project_dir "$KEY")/mined.json"
	run_hook

	[ "$(artifact_count)" -eq 1 ]
}

@test "does not advance the watermark when nothing could be written" {
	# ecosystem-449.55 one layer up: a watermark ahead of its data turns a
	# recoverable interruption into permanent silent loss, and hides it,
	# because the watermark is the thing asserting all is well.
	make_repo "fix(thing): a claim

Because reasons that are durable."
	archivist_storage_init "$KEY"
	chmod 555 "$(archivist_project_dir "$KEY")/decisions"

	run run_hook
	chmod 755 "$(archivist_project_dir "$KEY")/decisions"

	[ "$status" -eq 0 ]
	[ ! -f "$(archivist_project_dir "$KEY")/mined.json" ]
}

@test "mines nothing when the watermark is current" {
	# Every session after the first takes this path, so it must be cheap and
	# must not rewrite what is already there.
	make_repo "fix(thing): a claim

Because reasons that are durable."
	run_hook
	local before
	before=$(artifact_count)

	run run_hook

	[ "$status" -eq 0 ]
	[ "$(artifact_count)" -eq "$before" ]
}

@test "splits a squashed body into one artifact per authored message" {
	# What squash merging actually produces: every authored message behind a
	# bullet inside one carrying commit.
	make_repo "feat(x): the pull request title (#12)

* first subject

first body because reasons

* second subject

second body because other reasons"

	run run_hook

	[ "$status" -eq 0 ]
	[ "$(artifact_count)" -eq 2 ]
}

@test "skips a subject with no body" {
	# A claim with no rationale. The durability filter downstream drops it
	# anyway; not writing it keeps the store free of records nothing promotes.
	make_repo "chore: bump a thing"

	run run_hook

	[ "$status" -eq 0 ]
	[ "$(artifact_count)" -eq 0 ]
}

@test "exits 0 outside a git repository" {
	# No project key, nothing to do. The hook must never block session end.
	REPO="${BATS_TEST_TMPDIR}/loose"
	mkdir -p "$REPO"

	run run_hook

	[ "$status" -eq 0 ]
}

@test "recovers when the watermark names a commit this repo no longer has" {
	# A reclone or a rewritten history. Mining nothing forever would be the
	# quiet failure; content-addressed ids make starting over an overwrite.
	make_repo "fix(thing): a claim

Because reasons that are durable."
	archivist_storage_init "$KEY"
	printf '{"last_sha":"%s","at":"now"}\n' "$(printf '0%.0s' {1..40})" \
		> "$(archivist_project_dir "$KEY")/mined.json"

	run run_hook

	[ "$status" -eq 0 ]
	[ "$(artifact_count)" -eq 1 ]
}

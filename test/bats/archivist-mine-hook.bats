#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/archivist"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_DIR="${BATS_TEST_TMPDIR}/onlooker"

	source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
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
	KEY=$(onlooker_project_key "$REPO")
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

_mined_artifact() {
	find "$(archivist_project_dir "$KEY")/decisions" -name '*.json' | head -1
}

@test "records an absent session as null, not the string \"unknown\"" {
	# archivist-extract.sh:251 writes null when it has no session. mine wrote
	# the literal "unknown", which is well-formed and therefore indistinguishable
	# from a real id to every consumer: lineage and historian joins matched
	# nothing silently, and librarian copied it into source_session_ids, so a
	# proposal asserted provenance it never had. 644 of 733 artifacts on the
	# dogfood machine carried it. ONL-82.
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them on every restart."

	run run_hook
	[ "$status" -eq 0 ]

	run jq -e '.session_id == null' "$(_mined_artifact)"
	[ "$status" -eq 0 ]
}

@test "preserves the session id when the commit carries a Claude-Session trailer" {
	# The trailer is the only way a mined commit can know its session, so the
	# null above must not come at the cost of the case that does resolve.
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them on every restart.

Claude-Session: session_abc123XYZ"

	run run_hook
	[ "$status" -eq 0 ]

	run jq -r '.session_id' "$(_mined_artifact)"
	[ "$output" = "abc123XYZ" ]
}

# --- a re-mine must overwrite, not accumulate (ONL-169) ---------------------
#
# The existing idempotence test above re-runs the hook on an UNCHANGED commit,
# so the carrying date is identical and the id matches whether or not the id
# depends on that date. Every real re-mine changes the date: a squash, a
# rebase and a cherry-pick all rewrite it. These pin that case.
#
# Measured before the fix: 192 of 1011 mined artifacts in this repo's own store
# (18%) were duplicate content, and this repo guarantees it by mandating
# always-PR in CLAUDE.md.

@test "re-mining after a rebase rewrites the date and still leaves one artifact" {
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them on every restart."

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 1 ] || return 1
	before=$(find "$(archivist_project_dir "$KEY")/decisions" -name '*.json' | head -1)
	before_id=$(basename "$before" .json)

	# What a rebase does to a commit: same message, new sha, new committer date.
	# The old sha is then unreachable, so the hook drops its watermark and
	# re-mines from scratch -- the path whose comment promises that
	# "content-addressed ids make the re-mine an overwrite".
	GIT_COMMITTER_DATE="2027-03-04T05:06:07Z" git -C "$REPO" commit -q --amend --no-edit --date="2027-03-04T05:06:07Z"

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 1 ] || return 1
	after_id=$(basename "$(find "$(archivist_project_dir "$KEY")/decisions" -name '*.json' | head -1)" .json)
	# The id itself must not move either: evidence.artifact_ids cites it, and a
	# changed id leaves every lesson pointing at an artifact that is gone.
	[ "$before_id" = "$after_id" ]
}

@test "mining a squash-merged subject leaves one artifact, not a second" {
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them on every restart."

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 1 ] || return 1
	before_id=$(basename "$(find "$(archivist_project_dir "$KEY")/decisions" -name '*.json' | head -1)" .json)

	# What GitHub does when it squash-merges: the same message with the pull
	# request number appended to the subject.
	git -C "$REPO" commit -q --amend --no-edit -m "fix(thing): stop dropping events :bug: (#450)

Because the old path dropped them on every restart."

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 1 ] || return 1
	after_id=$(basename "$(find "$(archivist_project_dir "$KEY")/decisions" -name '*.json' | head -1)" .json)
	[ "$before_id" = "$after_id" ]
}

# --- a body that is only metadata is not a rationale (ONL-170) --------------
#
# The only filter before this was "a subject with no body is a claim with no
# rationale". A release-please commit HAS a body -- and after the squash split
# consumes its changelog bullets, what remains as that body is a
# `Co-authored-by:` trailer. So 84 of them became decision artifacts, as did 67
# identical auto-format commits: 167 of 1011 artifacts in this repo's store
# (16%) came from commits nobody reasoned about, and each is paid for twice
# downstream, by the classifier and again by the lesson transform.
#
# This extends the existing rule rather than adding a new mechanism: a body
# made only of git trailers and separator rules carries no more rationale than
# an empty one.
#
# Measured against the alternatives, which all looked more principled and are
# all worse:
#   - the `Claude-Session:` trailer this hook already parses does NOT separate
#     them: 107 of 151 bot artifacts carry one.
#   - nor does the commit author: github-actions[bot] wrote 121, but 59 were
#     authored by a human, because squash-merging a release PR attributes the
#     squash to whoever merged it.
#   - the conventional-commit type is too blunt: skipping `chore` wholesale
#     also drops `chore(deps): require the schema that knows these events`,
#     a real decision, measured at ~49 records.
#   - a config'd subject skip-list works but rots, and needs every consumer to
#     know this repo's conventions.
# The trailer rule caught 173 records, 155 of them that bot noise. The other 18
# are human commits with a subject and no written rationale, which the rule one
# line up already says should not be artifacts.

@test "a release-please body of nothing but a trailer is not mined" {
	# The real shape, from this repo's own store: the changelog bullets are
	# consumed by the squash split and the surviving body is one trailer.
	make_repo "chore: release main

Co-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 0 ]
}

@test "an auto-format body of a rule and a trailer is not mined" {
	make_repo "style: auto-format :art:

---------

Co-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 0 ]
}

@test "prose followed by trailers is still mined" {
	# The precision guard that matters most: almost every real commit in this
	# repo ends with trailers. Stripping them must not strip the reasoning
	# above them.
	make_repo "fix(thing): stop dropping events :bug:

Because the old path dropped them on every restart, and the watermark was
the thing asserting all was well.

Refs ONL-123
Co-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 1 ]
}

@test "a chore with a real rationale is still mined" {
	# A type-wide skip on `chore` would eat this, and it is exactly the kind of
	# record the pipeline exists for.
	make_repo "chore(deps): require the schema that knows these events :arrow_up:

The emitter validates against the published package, so the bats suite fails
until the release that registers these types is out."

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 1 ]
}

@test "a one-line body that is a bare separator is not mined" {
	make_repo "chore: tidy something

---------"

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 0 ]
}

@test "skipping every commit still advances the watermark" {
	# Otherwise a run of nothing but automation is re-examined on every session
	# end, forever. "Deliberately skipped" and "could not be written" are
	# different outcomes and the watermark must not conflate them -- the same
	# instrument ambiguity ONL-10 closed one layer up.
	make_repo "chore: release main

Co-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 0 ] || return 1
	[ -f "$(archivist_project_dir "$KEY")/mined.json" ]
}

@test "a failed write still does not advance the watermark" {
	# The other half of that distinction, kept explicit: a skip advances, a
	# failure does not. ecosystem-449.55 is what the inverse costs.
	make_repo "fix(thing): a claim

Because reasons that are durable."
	archivist_storage_init "$KEY"
	chmod 555 "$(archivist_project_dir "$KEY")/decisions"

	run run_hook
	chmod 755 "$(archivist_project_dir "$KEY")/decisions"

	[ "$status" -eq 0 ] || return 1
	[ ! -f "$(archivist_project_dir "$KEY")/mined.json" ]
}

@test "prose that merely looks like a trailer is still mined" {
	# Why the trailer list is CLOSED rather than a `^Word:` pattern. These two
	# lines are the reasoning, not metadata, and a generic pattern strips both.
	# Measured: the generic pattern caught 7 more records than the closed list
	# across this repo's store, and those 7 were prose.
	make_repo "fix(thing): stop dropping events :bug:

Problem: events were dropped on every restart.
Note: the watermark was the thing asserting all was well.

Co-authored-by: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>"

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 1 ]
}

# --- a backlog must drain, not wedge ----------------------------------------
#
# The CLI kills the whole SessionEnd batch at 1500ms, and a plugin's declared
# timeout does not raise that (#338). At 43-62ms a commit, anything past about
# 25 commits behind could not finish, and because the watermark moved only at
# the end, every killed run saved nothing: the dotfiles repo sat 182 commits
# behind for almost four weeks, cancelled on every session end. These pin the
# two halves of the fix -- a bounded slice per run, and progress that survives
# a run that stops partway.

add_commit() {
	printf '%s\n' "$RANDOM$RANDOM" >> "$REPO/a.txt"
	git -C "$REPO" add .
	git -C "$REPO" commit -q -m "$1"
}

# n commits, each a distinct decision with a rationale.
make_backlog() {
	local n="$1" i
	make_repo "fix(c1): decision one

Because reason one."
	for (( i = 2; i <= n; i++ )); do
		add_commit "fix(c${i}): decision ${i}

Because reason ${i}."
	done
}

set_max_commits() {
	mkdir -p "${HOME}/.claude"
	printf '{"archivist":{"mining":{"max_commits_per_run":%s}}}\n' "$1" \
		> "${HOME}/.claude/settings.json"
}

watermark() {
	jq -r '.last_sha' "$(archivist_project_dir "$KEY")/mined.json"
}

@test "mines at most max_commits_per_run, oldest first" {
	make_backlog 3
	set_max_commits 2

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 2 ] || return 1
	# Oldest first, so the watermark sits on the second commit and the third is
	# still ahead of it -- the newest work is what waits, never a gap.
	[ "$(watermark)" = "$(git -C "$REPO" rev-parse HEAD~1)" ] || return 1
	run grep -l "decision 3" "$(archivist_project_dir "$KEY")/decisions"/*.json
	[ "$status" -ne 0 ]
}

@test "a backlog larger than the cap drains over successive sessions" {
	make_backlog 5
	set_max_commits 2

	run_hook
	run_hook
	run run_hook

	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 5 ] || return 1
	[ "$(watermark)" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "a run that stops partway keeps the commits it finished" {
	# Stands in for the deadline kill: a run that does not reach its end. Before,
	# the watermark was written once after the loop, so commit 1's work was
	# thrown away along with commit 2's and the next run started over.
	make_backlog 2
	source "${PLUGIN_ROOT}/scripts/lib/archivist-ulid.sh"
	source "${PLUGIN_ROOT}/scripts/lib/archivist-mine.sh"
	local body record id
	body=$(git -C "$REPO" log -1 --format='%B' HEAD)
	IFS= read -r -d '' record < <(archivist_mine_split "$body") || true
	id=$(archivist_mine_id "$record")
	archivist_storage_init "$KEY"
	# A directory where commit 2's artifact goes makes exactly that write fail.
	mkdir -p "$(archivist_project_dir "$KEY")/decisions/${id}.json"

	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(watermark)" = "$(git -C "$REPO" rev-parse HEAD~1)" ] || return 1

	# And the next session picks up exactly where that one stopped.
	rmdir "$(archivist_project_dir "$KEY")/decisions/${id}.json"
	run run_hook
	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 2 ] || return 1
	[ "$(watermark)" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

@test "the shipped default caps a run at 10 commits" {
	# Pins config.json, so the default that keeps a run under the deadline cannot
	# be dropped without a test noticing.
	make_backlog 12

	run run_hook

	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 10 ]
}

@test "max_commits_per_run of 0 removes the cap" {
	make_backlog 12
	set_max_commits 0

	run run_hook

	[ "$status" -eq 0 ] || return 1
	[ "$(artifact_count)" -eq 12 ] || return 1
	[ "$(watermark)" = "$(git -C "$REPO" rev-parse HEAD)" ]
}

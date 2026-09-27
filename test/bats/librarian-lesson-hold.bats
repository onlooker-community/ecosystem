#!/usr/bin/env bats
#
# `run --separate-stderr` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0
#
# The hold: a model-asserted lesson is promoted into approved_held/ instead of
# approved/, so `onlooker sync` (which reads only approved/*.json) cannot see
# it until something moves it out. A human-asserted lesson is unaffected.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
}

_evidence() {
	printf '%s' '{"artifact_ids":["01KZ45MKAM734ZS7JK24D2DK0R"],"session_ids":["s1"],"project_key":"6a7678979e31","observed_at":"2026-08-03T15:59:48Z","resolution":"Pin vitest to 3.x."}'
}

# Usage: _candidate <scope_json>
_candidate() {
	jq -cn --argjson ev "$(_evidence)" --argjson scope "$1" \
		'{claim: "c", rationale: "r", evidence: $ev,
		  applies_to: {stack: ["vite"], scope: $scope, file_patterns: [], task_kinds: []}}'
}

_indep() { printf '%s' '{"kind":"version_independent","justification":"git aborts checkout on a dirty tree regardless of version."}'; }

_hold_setup() {
	for lib in librarian-project-key librarian-ulid librarian-storage \
		librarian-lesson-storage librarian-lesson-validate librarian-config \
		librarian-author-key librarian-lesson-promote; do
		# shellcheck disable=SC1091
		source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh"
	done
	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-hold.git
	PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"
	librarian_config_load "$PROJECT_REPO"
}

# $1 = lesson id, $2 = asserted_by ("human" or "model")
_seed_judged() {
	local id="$1" asserted="$2"
	jq -cn --arg id "$id" --arg a "$asserted" \
		--argjson cand "$(_candidate "$(_indep)")" \
		'{id: $id, status: "approved", visibility: "public",
		  artifact_id: "01KZ45MKAM734ZS7JK24D2DK0R", candidate: $cand,
		  asserted_by: $a, judged_at: "2026-09-26T12:00:00Z",
		  verdict: {passed: true, judges: [{passed: true}, {passed: true}]}}' \
		> "${LESSONS_DIR}/proposals/${id}.json"
}

@test "storage_init creates approved_held" {
	_hold_setup
	[ -d "${LESSONS_DIR}/approved_held" ]
}

@test "a model-asserted lesson is promoted into approved_held, not approved" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	run librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	[ "$status" -eq 0 ]
	[ -f "${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670K.json" ]
	[ ! -f "${LESSONS_DIR}/approved/01M3B87J7046SJE5BECNMP670K.json" ]
}

@test "the hold stamps shippable_after on the envelope, never on the pool entry" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	run librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	[ "$status" -eq 0 ]
	jq -e '.shippable_after | type == "string"' \
		"${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670K.json"
	# ZLesson is a strictObject: an extra key fails ingest at sync.
	jq -e 'has("shippable_after") | not' \
		"${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670K.json"
}

@test "a human-asserted lesson still goes straight to approved" {
	_hold_setup
	_seed_judged 01M33440PGTWP4QMMG1BVA52DR human
	run librarian_lesson_promote "$PROJECT_KEY" 01M33440PGTWP4QMMG1BVA52DR
	[ "$status" -eq 0 ]
	[ -f "${LESSONS_DIR}/approved/01M33440PGTWP4QMMG1BVA52DR.json" ]
	[ ! -f "${LESSONS_DIR}/approved_held/01M33440PGTWP4QMMG1BVA52DR.json" ]
}

@test "an envelope with no asserted_by is treated as human" {
	_hold_setup
	_seed_judged 01M3ASXRSRGY9TXKV045NK8V7G human
	# Remove the field entirely: every proposal written before this change.
	tmp=$(mktemp); jq 'del(.asserted_by)' \
		"${LESSONS_DIR}/proposals/01M3ASXRSRGY9TXKV045NK8V7G.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M3ASXRSRGY9TXKV045NK8V7G.json"
	run librarian_lesson_promote "$PROJECT_KEY" 01M3ASXRSRGY9TXKV045NK8V7G
	[ "$status" -eq 0 ]
	[ -f "${LESSONS_DIR}/approved/01M3ASXRSRGY9TXKV045NK8V7G.json" ]
}

@test "the sweep moves a held lesson whose window has elapsed" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	# Backdate the window so it is already past.
	tmp=$(mktemp); jq '.shippable_after = "2020-01-01T00:00:00Z"' \
		"${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670K.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670K.json"

	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	[[ "$output" == *"01M3B87J7046SJE5BECNMP670K"* ]]
	[ -f "${LESSONS_DIR}/approved/01M3B87J7046SJE5BECNMP670K.json" ]
	[ ! -f "${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670K.json" ]
}

@test "the sweep leaves a held lesson whose window has not elapsed" {
	_hold_setup
	_seed_judged 01M33440PGTWP4QMMG1BVA52DR model
	librarian_lesson_promote "$PROJECT_KEY" 01M33440PGTWP4QMMG1BVA52DR
	tmp=$(mktemp); jq '.shippable_after = "2099-01-01T00:00:00Z"' \
		"${LESSONS_DIR}/proposals/01M33440PGTWP4QMMG1BVA52DR.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M33440PGTWP4QMMG1BVA52DR.json"

	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ -f "${LESSONS_DIR}/approved_held/01M33440PGTWP4QMMG1BVA52DR.json" ]
}

@test "a held lesson with no readable envelope is left alone, not shipped" {
	_hold_setup
	_seed_judged 01M3ASXRSRGY9TXKV045NK8V7G model
	librarian_lesson_promote "$PROJECT_KEY" 01M3ASXRSRGY9TXKV045NK8V7G
	rm -f "${LESSONS_DIR}/proposals/01M3ASXRSRGY9TXKV045NK8V7G.json"
	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	# Unknown window must fail closed: a lesson whose window cannot be read
	# must never be shipped by default.
	[ -f "${LESSONS_DIR}/approved_held/01M3ASXRSRGY9TXKV045NK8V7G.json" ]
}

@test "a held lesson with a malformed shippable_after stays held" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670Z model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670Z
	tmp=$(mktemp); jq '.shippable_after = "soon"' \
		"${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670Z.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670Z.json"

	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	# A value that isn't the exact fixed-width RFC3339 UTC shape the writer
	# produces must fail closed exactly like a missing envelope: the lexical
	# compare is only sound once the shape is known, so junk stays held
	# rather than being fed into that compare either way.
	[ -z "$output" ]
	[ -f "${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670Z.json" ]
	[ ! -f "${LESSONS_DIR}/approved/01M3B87J7046SJE5BECNMP670Z.json" ]
}

@test "the sweep is idempotent" {
	_hold_setup
	_seed_judged 01M3B93JPGAKHGEQ5KD9N836HD model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B93JPGAKHGEQ5KD9N836HD
	tmp=$(mktemp); jq '.shippable_after = "2020-01-01T00:00:00Z"' \
		"${LESSONS_DIR}/proposals/01M3B93JPGAKHGEQ5KD9N836HD.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/01M3B93JPGAKHGEQ5KD9N836HD.json"
	librarian_lesson_sweep_held "$PROJECT_KEY"
	run librarian_lesson_sweep_held "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "count_held counts only what is still held" {
	_hold_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	run librarian_lesson_count_held "$PROJECT_KEY"
	[ "$output" -eq 1 ]
}

_hold_cli_setup() {
	_hold_setup
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-cli.sh"
}

@test "lessons queue lists a held lesson with its window" {
	_hold_cli_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	run librarian_cli lessons queue "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"01M3B87J7046SJE5BECNMP670K"* ]]
	[[ "$output" == *"shippable"* ]]
}

@test "lessons queue says so when nothing is held" {
	_hold_cli_setup
	run librarian_cli lessons queue "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nothing is waiting to leave"* ]]
}

@test "lessons veto removes a held lesson and tombstones it" {
	_hold_cli_setup
	_seed_judged 01M33440PGTWP4QMMG1BVA52DR model
	librarian_lesson_promote "$PROJECT_KEY" 01M33440PGTWP4QMMG1BVA52DR
	run librarian_cli lessons veto 01M33440PGTWP4QMMG1BVA52DR "overreaches" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ ! -f "${LESSONS_DIR}/approved_held/01M33440PGTWP4QMMG1BVA52DR.json" ]
	[ ! -f "${LESSONS_DIR}/approved/01M33440PGTWP4QMMG1BVA52DR.json" ]
	tail -n 1 "${LESSONS_DIR}/declined.jsonl" | jq -e '.reason == "vetoed"'
}

@test "lessons veto refuses a lesson that is not held" {
	_hold_cli_setup
	# --separate-stderr: plain `run` merges stdout and stderr into $output, so
	# a refusal message printed only to stderr could still make an assertion
	# against $output pass without proving anything about which stream it
	# landed on. See the same rationale in librarian-author-key.bats.
	run --separate-stderr librarian_cli lessons veto 01M3ASXRSRGY9TXKV045NK8V7G "" "$PROJECT_REPO"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"not held"* ]]
	[[ "$output" != *"not held"* ]]
}

@test "lessons veto refuses and says so when the lesson has already shipped" {
	_hold_cli_setup
	_seed_judged 01M3CQEG6ZR2E4XJ0K6WY9J1QD human
	librarian_lesson_promote "$PROJECT_KEY" 01M3CQEG6ZR2E4XJ0K6WY9J1QD
	run --separate-stderr librarian_cli lessons veto 01M3CQEG6ZR2E4XJ0K6WY9J1QD "" "$PROJECT_REPO"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"already shipped"* ]]
	[[ "$output" != *"already shipped"* ]]
}

@test "lessons veto refuses and says so when the lesson was never promoted" {
	_hold_cli_setup
	_seed_judged 01M3DHRTC1ZQXWQ5V7Y9F0K3MB model
	run --separate-stderr librarian_cli lessons veto 01M3DHRTC1ZQXWQ5V7Y9F0K3MB "" "$PROJECT_REPO"
	[ "$status" -ne 0 ]
	[[ "$stderr" == *"never promoted"* ]]
	[[ "$output" != *"never promoted"* ]]
}

@test "lessons veto still succeeds and warns on stderr when the proposal is unreadable" {
	_hold_cli_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	# Same shape as the sweep's "no readable envelope" test above: the proposal
	# that would have carried artifact_id is gone, so it can't be resolved.
	rm -f "${LESSONS_DIR}/proposals/01M3B87J7046SJE5BECNMP670K.json"
	run --separate-stderr librarian_cli lessons veto 01M3B87J7046SJE5BECNMP670K "" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ ! -f "${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670K.json" ]
	[[ "$stderr" == *"artifact_id could not be resolved"* ]]
	[[ "$stderr" == *"no declined-ledger row was recorded"* ]]
	[[ "$output" != *"artifact_id could not be resolved"* ]]
	[[ "$output" == *"vetoed; it will not leave this machine"* ]]
}

@test "veto still succeeds and warns on stderr when the declined-ledger row cannot be written" {
	_hold_cli_setup
	_seed_judged 01M3B87J7046SJE5BECNMP670K model
	librarian_lesson_promote "$PROJECT_KEY" 01M3B87J7046SJE5BECNMP670K
	# librarian_lesson_append_declined's last statement is `printf >>
	# declined.jsonl`. Replacing that file with a directory leaves
	# librarian_lesson_storage_init (mkdir -p, already exists) succeeding
	# while the trailing append fails — the exact mechanism the veto ruling
	# was verified against by reading the source alone; this test drives it.
	mkdir -p "${LESSONS_DIR}/declined.jsonl"
	run --separate-stderr librarian_cli lessons veto 01M3B87J7046SJE5BECNMP670K "overreaches" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ ! -f "${LESSONS_DIR}/approved_held/01M3B87J7046SJE5BECNMP670K.json" ]
	[[ "$stderr" == *"declined-ledger row could not be written"* ]]
	[[ "$output" != *"declined-ledger row could not be written"* ]]
	[[ "$output" == *"vetoed; it will not leave this machine"* ]]
}

#!/usr/bin/env bats
#
# Lesson confirmation: the human intent filter between the transform and the
# jury. Assertions use [ ] or `|| return 1` so every one gates under bash 3.2.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
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

_versioned() { printf '%s' '{"kind":"versioned","versions":{"vite":"<6"}}'; }
_indep() { printf '%s' '{"kind":"version_independent","justification":"git aborts checkout on a dirty tree regardless of version."}'; }

@test "confirmed validator accepts a versioned candidate" {
	run librarian_lesson_validate_confirmed "$(_candidate "$(_versioned)")"
	[ "$status" -eq 0 ]
}

@test "confirmed validator accepts version_independent with a justification" {
	run librarian_lesson_validate_confirmed "$(_candidate "$(_indep)")"
	[ "$status" -eq 0 ]
}

@test "confirmed validator rejects version_independent with an empty justification" {
	run librarian_lesson_validate_confirmed \
		"$(_candidate '{"kind":"version_independent","justification":""}')"
	[ "$status" -eq 1 ]
}

@test "confirmed validator rejects version_independent with no justification key" {
	run librarian_lesson_validate_confirmed \
		"$(_candidate '{"kind":"version_independent"}')"
	[ "$status" -eq 1 ]
}

@test "confirmed validator rejects an unknown scope kind" {
	run librarian_lesson_validate_confirmed \
		"$(_candidate '{"kind":"whenever","justification":"x"}')"
	[ "$status" -eq 1 ]
}

@test "confirmed validator still enforces the range pattern on versioned scope" {
	run librarian_lesson_validate_confirmed \
		"$(_candidate '{"kind":"versioned","versions":{"vite":"^5.4.21"}}')"
	[ "$status" -eq 1 ]
}

@test "confirmed validator still enforces provenance" {
	candidate=$(_candidate "$(_versioned)" | jq -c '.evidence.session_ids = [""]')
	run librarian_lesson_validate_confirmed "$candidate"
	[ "$status" -eq 1 ]
}

@test "confirmed validator still enforces the versions-subset-of-stack rule" {
	candidate=$(_candidate '{"kind":"versioned","versions":{"vite":"<6","vitest":">=4"}}')
	run librarian_lesson_validate_confirmed "$candidate"
	[ "$status" -eq 1 ]
}

@test "the transform validator still refuses version_independent" {
	run librarian_lesson_validate_candidate "$(_candidate "$(_indep)")"
	[ "$status" -eq 1 ]
}

_review_setup() {
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-review.sh"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-review.git
	PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"
}

# Seeds one pending proposal and prints its id.
_seed_pending() {
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "$(_versioned)")" "01KZ45MKAM734ZS7JK24D2DK0R"
}

@test "list_pending returns an empty array when the queue is empty" {
	_review_setup
	run librarian_lesson_list_pending "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
}

@test "list_pending returns a seeded pending proposal" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_list_pending "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -e --arg id "$id" 'length == 1 and .[0].id == $id' >/dev/null
}

@test "confirm records status and visibility on the proposal" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	[ "$status" -eq 0 ]
	jq -e '.status == "confirmed" and .visibility == "org"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm refuses an empty visibility and leaves the proposal pending" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" ""
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm refuses an unknown visibility" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "everyone"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm with a justification rewrites scope to version_independent" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git behavior is stable across versions."
	[ "$status" -eq 0 ]
	jq -e '.candidate.applies_to.scope.kind == "version_independent"
	       and (.candidate.applies_to.scope.justification | length) > 0' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm refuses version_independent at private visibility" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "private" "stable across versions."
	[ "$status" -ne 0 ]
	jq -e '.status == "pending" and .candidate.applies_to.scope.kind == "versioned"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm refuses a candidate that fails the confirmed validator" {
	_review_setup
	id=$(_seed_pending)
	# Corrupt the stored candidate so validation must reject it.
	tmp="${BATS_TEST_TMPDIR}/bad.json"
	jq '.candidate.evidence.resolution = ""' "${LESSONS_DIR}/proposals/${id}.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/${id}.json"
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "pass marks the proposal and appends one ledger line" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_pass "$PROJECT_KEY" "$id" "not worth sharing"
	[ "$status" -eq 0 ]
	jq -e '.status == "passed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
	[ "$(wc -l < "${LESSONS_DIR}/passed.jsonl")" -eq 1 ]
	tail -n 1 "${LESSONS_DIR}/passed.jsonl" \
		| jq -e --arg id "$id" '.lesson_id == $id and .reason == "not worth sharing"' >/dev/null
}

@test "a passed proposal keeps its file so the artifact stays seen" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_pass "$PROJECT_KEY" "$id"
	[ -f "${LESSONS_DIR}/proposals/${id}.json" ]
	run librarian_lesson_seen "$PROJECT_KEY" "01KZ45MKAM734ZS7JK24D2DK0R"
	[ "$status" -eq 0 ]
}

@test "this stage never writes to declined.jsonl" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	id2=$(_seed_pending)
	librarian_lesson_pass "$PROJECT_KEY" "$id2"
	[ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "confirming never invokes a model" {
	_review_setup
	# A claude on PATH that fails loudly if called at all.
	stub="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub"
	printf '#!/usr/bin/env bash\necho "MODEL WAS INVOKED" >&2\nexit 42\n' > "${stub}/claude"
	chmod +x "${stub}/claude"
	PATH="${stub}:${PATH}"

	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	[ "$status" -eq 0 ]
	[[ "$output" != *"MODEL WAS INVOKED"* ]] || return 1
	jq -e '.status == "confirmed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "list_pending excludes confirmed and passed proposals" {
	_review_setup
	a=$(_seed_pending); b=$(_seed_pending); c=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$a" "org"
	librarian_lesson_pass "$PROJECT_KEY" "$b"
	run librarian_lesson_list_pending "$PROJECT_KEY"
	printf '%s' "$output" | jq -e --arg c "$c" 'length == 1 and .[0].id == $c' >/dev/null
}

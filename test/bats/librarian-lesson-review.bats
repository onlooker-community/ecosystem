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

@test "confirm refuses a candidate that already carries version_independent scope at private visibility" {
	_review_setup
	# Seeded directly with version_independent scope and no justification
	# argument on this call — librarian_lesson_write_proposal performs no
	# validation, so this is reachable without going through the input-side
	# guard at all. The guard must key on the resulting state, not on
	# whether THIS call passed a justification.
	id=$(librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "$(_indep)")" "01KZ45MKAM734ZS7JK24D2DK0R")
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "private"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending" and .candidate.applies_to.scope.kind == "version_independent"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirm accepts a candidate that already carries version_independent scope at org visibility" {
	_review_setup
	id=$(librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "$(_indep)")" "01KZ45MKAM734ZS7JK24D2DK0R")
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	[ "$status" -eq 0 ]
	jq -e '.status == "confirmed" and .candidate.applies_to.scope.kind == "version_independent"' \
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

@test "confirming an already-confirmed lesson with the same visibility succeeds and does not write twice" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	before=$(cat "${LESSONS_DIR}/proposals/${id}.json")
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	[ "$status" -eq 0 ]
	after=$(cat "${LESSONS_DIR}/proposals/${id}.json")
	[ "$before" = "$after" ]
}

@test "confirming an already-confirmed lesson with a different visibility is refused" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	[ "$status" -ne 0 ]
	jq -e '.status == "confirmed" and .visibility == "org"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "confirming a passed lesson is refused" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_pass "$PROJECT_KEY" "$id"
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	[ "$status" -ne 0 ]
	jq -e '.status == "passed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "passing an already-passed lesson does not append a second ledger line" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_pass "$PROJECT_KEY" "$id" "not worth sharing"
	run librarian_lesson_pass "$PROJECT_KEY" "$id" "still not worth sharing"
	[ "$status" -eq 0 ]
	[ "$(wc -l < "${LESSONS_DIR}/passed.jsonl")" -eq 1 ]
	tail -n 1 "${LESSONS_DIR}/passed.jsonl" \
		| jq -e --arg id "$id" '.lesson_id == $id and .reason == "not worth sharing"' >/dev/null
}

@test "passing a confirmed lesson is refused" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	run librarian_lesson_pass "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	jq -e '.status == "confirmed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
	[ ! -f "${LESSONS_DIR}/passed.jsonl" ]
}

@test "list_pending still returns the good entries when the directory also contains a truncated file, a bare-number file, and an empty file" {
	_review_setup
	id=$(_seed_pending)
	printf '{"id":"bad","status":"pending"' > "${LESSONS_DIR}/proposals/truncated.json"
	printf '123' > "${LESSONS_DIR}/proposals/barenum.json"
	: > "${LESSONS_DIR}/proposals/empty.json"
	run librarian_lesson_list_pending "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -e --arg id "$id" 'length == 1 and .[0].id == $id' >/dev/null
}

@test "confirming with a justification stores scope with exactly kind and justification, no versions key surviving" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git behavior is stable across versions."
	[ "$status" -eq 0 ]
	jq -e '.candidate.applies_to.scope | keys == ["justification", "kind"]' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "the stored candidate still passes the confirmed validator after a version_independent confirm" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git behavior is stable across versions."
	stored=$(jq -c '.candidate' "${LESSONS_DIR}/proposals/${id}.json")
	run librarian_lesson_validate_confirmed "$stored"
	[ "$status" -eq 0 ]
}

@test "an identical repeat confirm with a justification is idempotent and succeeds" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git behavior is stable across versions."
	before=$(cat "${LESSONS_DIR}/proposals/${id}.json")
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git behavior is stable across versions."
	[ "$status" -eq 0 ]
	after=$(cat "${LESSONS_DIR}/proposals/${id}.json")
	[ "$before" = "$after" ]
}

@test "a repeat confirm with a different justification is refused" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git behavior is stable across versions."
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "a completely different justification."
	[ "$status" -ne 0 ]
	jq -e '.candidate.applies_to.scope.justification == "git behavior is stable across versions."' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

_cli_setup() {
	_review_setup
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-cli.sh"
}

@test "lessons status reports zero on an empty queue" {
	_cli_setup
	run librarian_cli lessons status "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"0"* ]] || return 1
}

@test "lessons list shows a pending lesson" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons list "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$id"* ]] || return 1
}

@test "lessons show prints the claim" {
	_cli_setup
	claim="pin vitest below six to avoid the esm regression"
	candidate=$(_candidate "$(_versioned)" | jq -c --arg c "$claim" '.claim = $c')
	id=$(librarian_lesson_write_proposal "$PROJECT_KEY" "$candidate" "01KZ45MKAM734ZS7JK24D2DK0R")
	run librarian_cli lessons show "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"claim:       ${claim}"* ]] || return 1
}

@test "lessons confirm requires a visibility argument" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons confirm sets status and visibility" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id" public "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.status == "confirmed" and .visibility == "public"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons confirm treats a bare trailing positional as cwd, not justification" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id" org "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.status == "confirmed" and .candidate.applies_to.scope.kind == "versioned"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons confirm threads --justification through to a version_independent rewrite" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id" org --justification "git behavior is stable across versions." "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.candidate.applies_to.scope.kind == "version_independent"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons confirm refuses a whitespace-only --justification instead of flipping scope" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id" org --justification "   " "$PROJECT_REPO"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending" and .candidate.applies_to.scope.kind == "versioned"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons confirm refuses an unknown flag instead of swallowing it" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id" org --foo "$PROJECT_REPO"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons confirm refuses a typo'd --justifcation instead of confirming with an empty justification" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons confirm "$id" org --justifcation "reason" "$PROJECT_REPO"
	[ "$status" -ne 0 ]
	jq -e '.status == "pending" and .candidate.applies_to.scope.kind == "versioned"' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons pass marks it passed" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons pass "$id" "" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.status == "passed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "lessons pass refuses a flag-shaped reason instead of storing it literally" {
	_cli_setup
	id=$(_seed_pending)
	# The likeliest typo for confirm's --justification. Positionally this
	# would otherwise land as the literal reason, with cwd falling back to
	# $(pwd) — and passed.jsonl is append-only, so a bad reason here has no
	# CLI path back (see librarian_lesson_pass's `passed) return 0` guard).
	# cd into PROJECT_REPO first so a missing guard would actually resolve a
	# real project key via the $(pwd) fallback, the same way the reported
	# bug does — running this from an arbitrary bats tmpdir would mask a
	# missing guard behind an unrelated "project key not found".
	cd "$PROJECT_REPO" || return 1
	run librarian_cli lessons pass "$id" --reason
	[ "$status" -ne 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
	[ ! -f "${LESSONS_DIR}/passed.jsonl" ]
}

@test "lessons pass still works with a real reason and an explicit cwd" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons pass "$id" "a real reason" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.status == "passed"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
	tail -n 1 "${LESSONS_DIR}/passed.jsonl" \
		| jq -e --arg id "$id" '.lesson_id == $id and .reason == "a real reason"' >/dev/null
}

@test "lessons defer leaves it pending" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons defer "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json" >/dev/null
}

@test "an unknown lessons verb is rejected" {
	_cli_setup
	run librarian_cli lessons frobnicate
	[ "$status" -ne 0 ]
}

@test "memory verbs are unaffected by the lessons namespace" {
	_cli_setup
	run librarian_cli status "$PROJECT_REPO"
	[ "$status" -eq 0 ]
}

@test "confirm without a justification writes no snapshot" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	run jq -e 'has("candidate_before_confirm")' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -ne 0 ]
}

@test "confirm with a justification snapshots the pre-rewrite candidate" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "git aborts on a dirty tree regardless of version"
	run jq -e '.candidate_before_confirm.applies_to.scope.kind == "versioned"' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "unconfirm returns a confirmed lesson to pending and clears the decision" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	run jq -e '.status == "pending" and (has("visibility") | not) and (has("confirmed_at") | not)' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "the round trip leaves the proposal byte-identical to its pre-confirm state" {
	_review_setup
	id=$(_seed_pending)
	before="${BATS_TEST_TMPDIR}/before.json"
	cp "${LESSONS_DIR}/proposals/${id}.json" "$before"

	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public" "git behavior is stable across versions"
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"

	run diff <(jq -S . "$before") <(jq -S . "${LESSONS_DIR}/proposals/${id}.json")
	[ "$status" -eq 0 ]
}

@test "unconfirm restores versioned scope after a justification confirm" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org" "stable across versions"
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	run jq -e '.candidate.applies_to.scope.kind == "versioned"
	           and (has("candidate_before_confirm") | not)' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "after unconfirm a fresh confirm at a different visibility succeeds" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "private"
	[ "$status" -eq 0 ]
	run jq -e '.status == "confirmed" and .visibility == "private"' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "unconfirm from pending is a no-op success" {
	_review_setup
	id=$(_seed_pending)
	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	run jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "unconfirm refuses a passed lesson and leaves the ledger untouched" {
	_review_setup
	id=$(_seed_pending)
	librarian_lesson_pass "$PROJECT_KEY" "$id" "not worth sharing"
	before_lines=$(wc -l < "${LESSONS_DIR}/passed.jsonl")

	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	run jq -e '.status == "passed"' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
	[ "$(wc -l < "${LESSONS_DIR}/passed.jsonl")" -eq "$before_lines" ]
}

@test "unconfirm refuses an unrecognized status and names it" {
	_review_setup
	id=$(_seed_pending)
	tmp="${BATS_TEST_TMPDIR}/mut.json"
	jq '.status = "judging"' "${LESSONS_DIR}/proposals/${id}.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/${id}.json"

	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	[[ "$output" == *"judging"* ]] || return 1
}

@test "unconfirm refuses a lesson that does not exist" {
	_review_setup
	run librarian_lesson_unconfirm "$PROJECT_KEY" "01KZNOSUCHLESSON0000000000"
	[ "$status" -ne 0 ]
}

@test "unconfirm never invokes a model" {
	_review_setup
	stub="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub"
	printf '#!/usr/bin/env bash\necho "MODEL WAS INVOKED" >&2\nexit 42\n' > "${stub}/claude"
	chmod +x "${stub}/claude"
	PATH="${stub}:${PATH}"

	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	[[ "$output" != *"MODEL WAS INVOKED"* ]] || return 1
}

@test "lessons unconfirm returns a confirmed lesson to pending" {
	_cli_setup
	id=$(_seed_pending)
	librarian_cli lessons confirm "$id" public "$PROJECT_REPO" >/dev/null
	run librarian_cli lessons unconfirm "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	run jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "lessons unconfirm requires a lesson id" {
	_cli_setup
	run librarian_cli lessons unconfirm
	[ "$status" -ne 0 ]
	# With no lesson id, cwd is empty too, so _librarian_cli_project_key
	# falls back to $(pwd) and resolves a valid key in this sandbox, and
	# librarian_lesson_unconfirm's own empty-id guard also returns 1. Exit
	# status alone can't tell the CLI's usage guard apart from that
	# fallback path. Pin the message: without the CLI guard this test would
	# pass while printing nothing useful.
	[[ "$output" == *"usage:"* && "$output" == *"unconfirm"* ]] || return 1
}

@test "lessons unconfirm rejects an unknown flag" {
	_cli_setup
	id=$(_seed_pending)
	librarian_cli lessons confirm "$id" public "$PROJECT_REPO" >/dev/null
	run librarian_cli lessons unconfirm "$id" --force
	[ "$status" -ne 0 ]
	# An invalid cwd already fails project-key resolution on its own, so the
	# exit code alone can't tell the guard's diagnostic apart from that
	# fallback path. Pin the message too: without the guard this would read
	# "No project key resolvable from this directory." instead.
	[[ "$output" == *"unknown option"* && "$output" == *"--force"* ]] || return 1
	run jq -e '.status == "confirmed"' "${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
}

@test "an unknown lessons verb is still rejected" {
	_cli_setup
	run librarian_cli lessons frobnicate
	[ "$status" -ne 0 ]
}

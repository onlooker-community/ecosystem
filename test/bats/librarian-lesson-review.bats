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
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-rubric.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-judge.sh"

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
	librarian_config_load "$PROJECT_REPO"
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

@test "list_by_status selects on the status it is handed, not just pending" {
	_review_setup
	a=$(_seed_pending)
	b=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$a" "org"
	run librarian_lesson_list_by_status "$PROJECT_KEY" "confirmed"
	[ "$status" -eq 0 ]
	printf '%s' "$output" \
		| jq -e --arg a "$a" --arg b "$b" \
			'length == 1 and .[0].id == $a and .[0].id != $b' >/dev/null
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

# ── lessons status: a count per status (ecosystem-sv3) ───────────────────────
#
# The judge walk used to close by reporting counts the model tracked itself
# across the loop, with nothing to check them against — every other walk in the
# skill ends on an authoritative CLI call. `lessons status` reported only a
# pending count, so there was nothing to ground the summary on.

# Force a proposal to a terminal status on disk. Reaching `approved` through
# the real path means empaneling a jury, which is what the judge walk exists to
# avoid doing twice; the status field is what the counter reads.
_set_status() {
	local id="$1" status="$2" promoted="${3:-}"
	local f
	f="$(librarian_lessons_dir "$PROJECT_KEY")/proposals/${id}.json"
	local tmp="${f}.tmp"
	if [[ -n "$promoted" ]]; then
		jq --arg s "$status" --arg p "$promoted" '.status = $s | .promoted_at = $p' "$f" >"$tmp"
	else
		jq --arg s "$status" '.status = $s | del(.promoted_at)' "$f" >"$tmp"
	fi
	mv -f "$tmp" "$f"
}

@test "lessons status reports zero on an empty queue" {
	_cli_setup
	run librarian_cli lessons status "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"0"* ]] || return 1
}

@test "lessons status reports a count for every status, not just pending" {
	_cli_setup
	local a b c d
	a=$(_seed_pending)
	b=$(_seed_pending)
	c=$(_seed_pending)
	d=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$b" "org"
	_set_status "$c" "approved" "2026-08-01T00:00:00Z"
	_set_status "$d" "rejected" "2026-08-01T00:00:00Z"

	run librarian_cli lessons status "$PROJECT_REPO"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"pending: 1"* ]] || return 1
	[[ "$output" == *"confirmed: 1"* ]] || return 1
	[[ "$output" == *"approved: 1"* ]] || return 1
	[[ "$output" == *"rejected: 1"* ]]
}

@test "lessons status counts a judged-but-unpromoted lesson separately" {
	# The judge walk's fourth bucket. promote() stamps promoted_at LAST, after
	# the terminal record lands, so a terminal status with no stamp is exactly
	# the state the walk is told not to fold into "approved" — the lesson has
	# no pool entry yet.
	_cli_setup
	local a b
	a=$(_seed_pending)
	b=$(_seed_pending)
	_set_status "$a" "approved" "2026-08-01T00:00:00Z"
	_set_status "$b" "approved"

	run librarian_cli lessons status "$PROJECT_REPO"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"approved: 2"* ]] || return 1
	[[ "$output" == *"awaiting promotion: 1"* ]]
}

@test "lessons status reports awaiting promotion for a rejected lesson too" {
	# A rejected verdict also lands its terminal record (the declined row)
	# before the stamp, so the same recovery state exists on that side.
	_cli_setup
	local a b
	a=$(_seed_pending)
	b=$(_seed_pending)
	_set_status "$a" "rejected"
	# A promoted sibling, so the count cannot come out right by counting every
	# rejected lesson — without it this passes whether or not the stamp is read.
	_set_status "$b" "rejected" "2026-08-01T00:00:00Z"

	run librarian_cli lessons status "$PROJECT_REPO"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"rejected: 2"* ]] || return 1
	[[ "$output" == *"awaiting promotion: 1"* ]]
}

@test "lessons status reports zeros across every status on an empty queue" {
	_cli_setup
	run librarian_cli lessons status "$PROJECT_REPO"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"pending: 0"* ]] || return 1
	[[ "$output" == *"confirmed: 0"* ]] || return 1
	[[ "$output" == *"approved: 0"* ]] || return 1
	[[ "$output" == *"rejected: 0"* ]] || return 1
	[[ "$output" == *"awaiting promotion: 0"* ]]
}

@test "lessons list shows a pending lesson" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons list "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$id"* ]] || return 1
}

@test "lessons list --confirmed shows a confirmed lesson the pending list hides" {
	_cli_setup
	id=$(_seed_pending)
	librarian_cli lessons confirm "$id" public "$PROJECT_REPO" >/dev/null

	run librarian_cli lessons list "$PROJECT_REPO"
	[[ "$output" == *"No pending lessons."* ]] || return 1

	run librarian_cli lessons list --confirmed "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"$id"* ]] || return 1
}

@test "lessons list --confirmed reports an empty set of its own" {
	_cli_setup
	_seed_pending
	# A pending lesson exists, so an implementation that ignored the flag
	# would print that row instead of the empty state.
	run librarian_cli lessons list --confirmed "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"No confirmed lessons."* ]] || return 1
}

@test "lessons list rejects an unknown flag instead of reading it as cwd" {
	_cli_setup
	_seed_pending
	cd "$PROJECT_REPO" || return 1
	run librarian_cli lessons list --passed
	[ "$status" -ne 0 ]
	# cd'd into the repo first so the cwd fallback resolves a real key: without
	# the guard this would print the pending queue and exit 0, not a path error.
	[[ "$output" == *"unknown option"* && "$output" == *"--passed"* ]] || return 1
}

@test "lessons show renders the visibility a confirmed lesson sits at" {
	_cli_setup
	id=$(_seed_pending)
	librarian_cli lessons confirm "$id" public "$PROJECT_REPO" >/dev/null
	run librarian_cli lessons show "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"visibility:  public"* ]] || return 1
}

@test "lessons show renders a dash for a pending lesson's visibility" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons show "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"visibility:  —"* ]] || return 1
	[[ "$output" != *"null"* ]] || return 1
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

@test "confirm without a justification clears a snapshot the proposal arrived with" {
	_review_setup
	id=$(_seed_pending)
	# Nothing in the shipped verbs writes this field onto a pending proposal
	# today, so seed it directly. The invariant unconfirm leans on is "absence
	# means the candidate was never mutated" — a stale snapshot surviving a
	# plain confirm would make the next unconfirm silently swap .candidate for
	# a rewrite that never happened, stranding the user in the dead end this
	# verb exists to escape.
	tmp="${BATS_TEST_TMPDIR}/stale.json"
	jq --argjson cb "$(_candidate "$(_indep)")" '.candidate_before_confirm = $cb' \
		"${LESSONS_DIR}/proposals/${id}.json" > "$tmp"
	mv "$tmp" "${LESSONS_DIR}/proposals/${id}.json"

	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	jq -e 'has("candidate_before_confirm") | not' \
		"${LESSONS_DIR}/proposals/${id}.json" >/dev/null || return 1

	# And the harm it would have caused: unconfirm must find nothing to restore.
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	run jq -e '.candidate.applies_to.scope.kind == "versioned"' \
		"${LESSONS_DIR}/proposals/${id}.json"
	[ "$status" -eq 0 ]
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

@test "after unconfirm a justification confirm can be redone at private visibility" {
	_review_setup
	id=$(_seed_pending)
	# The composite the design actually argues for. A justification rewrites
	# scope to version_independent, and private refuses that scope — so without
	# the snapshot restore this last confirm is refused for a rewrite the user
	# already took back, trading one dead end for another. The plain-confirm
	# case above still passes with the snapshot mechanism deleted entirely;
	# this one does not.
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public" \
		"git aborts on a dirty tree regardless of version"
	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	run librarian_lesson_confirm "$PROJECT_KEY" "$id" "private"
	[ "$status" -eq 0 ]
	run jq -e '.status == "confirmed" and .visibility == "private"
	           and .candidate.applies_to.scope.kind == "versioned"' \
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

@test "lessons unconfirm on a pending lesson does not claim it undid a confirmation" {
	_cli_setup
	id=$(_seed_pending)
	run librarian_cli lessons unconfirm "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	# The no-op is a success, but reporting "Unconfirmed <id>" for a lesson
	# nobody confirmed asserts an action that never happened — and a user
	# chasing a mistaken confirm would read it as proof they fixed it.
	[[ "$output" == *"already pending"* ]] || return 1
	[[ "$output" != *"Unconfirmed"* ]] || return 1
}

@test "lessons unconfirm still reports the action when it took one" {
	_cli_setup
	id=$(_seed_pending)
	librarian_cli lessons confirm "$id" public "$PROJECT_REPO" >/dev/null
	run librarian_cli lessons unconfirm "$id" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Unconfirmed ${id}"* ]] || return 1
	[[ "$output" != *"already pending"* ]] || return 1
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

@test "unconfirm refuses an approved lesson, naming the status" {
	_review_setup
	local id
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	# criterion_scores must cover the rubric's floored criteria or the judge
	# refuses the panel as UNJUDGED and this lesson never reaches `approved`.
	librarian_lesson_judge "$PROJECT_KEY" "$id" \
		'[{"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9}},{"judge_type":"adversarial","score":0.8,"passed":true,"criterion_scores":{"grounding":0.8,"scope_accuracy":0.8,"generality":0.8}}]'

	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unrecognized status"* && "$output" == *"approved"* ]] || return 1
}

@test "unconfirm refuses a rejected lesson, naming the status" {
	_review_setup
	local id
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	# As above: the public rubric floors disclosure too, so it must be scored
	# for the panel to produce a verdict at all. The jury split is what rejects.
	librarian_lesson_judge "$PROJECT_KEY" "$id" \
		'[{"judge_type":"standard","score":0.95,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.95,"disclosure":0.95}},{"judge_type":"adversarial","score":0.75,"passed":false,"criterion_scores":{"grounding":0.75,"scope_accuracy":0.75,"generality":0.75,"disclosure":0.95}}]'

	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unrecognized status"* && "$output" == *"rejected"* ]] || return 1
}

@test "confirm writes the proposal atomically, never truncating in place" {
	# `printf > path` truncates first, so an interrupted write leaves a
	# zero-byte proposal that every verb refuses and list_pending hides —
	# unrecoverable even by unconfirm. A read-only-dir test would NOT catch
	# this: it blocks the open entirely, so the truncating code also leaves
	# the original intact. What distinguishes atomic from not is that the
	# write lands somewhere else first, so spy on the rename.
	_review_setup
	local id
	id=$(_seed_pending)

	local marker="${BATS_TEST_TMPDIR}/mv-called"
	rm -f "$marker"
	mv() { printf '%s -> %s\n' "$1" "$2" >> "$marker"; command mv "$@"; }

	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"

	[ -f "$marker" ]
	grep -q "proposals/${id}.json" "$marker" || return 1
	[ "$(jq -r '.status' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/${id}.json")" = "confirmed" ]
	unset -f mv
}

@test "pass writes the proposal atomically, never truncating in place" {
	# Same discriminator as confirm's atomic-write test: a read-only-dir test
	# would not catch a reverted fix here either, since the truncating write
	# also never opens the file. Spy on the rename instead.
	_review_setup
	local id
	id=$(_seed_pending)

	local marker="${BATS_TEST_TMPDIR}/mv-called"
	rm -f "$marker"
	mv() { printf '%s -> %s\n' "$1" "$2" >> "$marker"; command mv "$@"; }

	librarian_lesson_pass "$PROJECT_KEY" "$id" "not worth sharing"

	[ -f "$marker" ]
	grep -q "proposals/${id}.json" "$marker" || return 1
	[ "$(jq -r '.status' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/${id}.json")" = "passed" ]
	unset -f mv
}

@test "unconfirm writes the proposal atomically, never truncating in place" {
	# Same discriminator as confirm's atomic-write test. unconfirm is the
	# recovery verb for a stuck proposal, so a truncating write here is the
	# one that would leave it unrecoverable even from its own remedy.
	_review_setup
	local id
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"

	local marker="${BATS_TEST_TMPDIR}/mv-called"
	rm -f "$marker"
	mv() { printf '%s -> %s\n' "$1" "$2" >> "$marker"; command mv "$@"; }

	librarian_lesson_unconfirm "$PROJECT_KEY" "$id"

	[ -f "$marker" ]
	grep -q "proposals/${id}.json" "$marker" || return 1
	[ "$(jq -r '.status' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/${id}.json")" = "pending" ]
	unset -f mv
}

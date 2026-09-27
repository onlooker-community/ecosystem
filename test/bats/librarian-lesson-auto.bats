#!/usr/bin/env bats
#
# Task 4: who asserted a lesson's scope, and judging it accordingly. A
# model-asserted lesson is judged against a stricter rubric than a
# human-asserted one, at every tier that runs a jury at all.

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

# A parked candidate: the transform could not bind a range and left the scope to
# a human. Legal while pending and nowhere else (ONL-107).
_unscoped() { printf '%s' '{"kind":"unscoped"}'; }

# A bound candidate: needs no justification to confirm.
_versioned() { printf '%s' '{"kind":"versioned","versions":{"vite":"<6"}}'; }

_auto_setup() {
	for lib in librarian-project-key librarian-ulid librarian-storage \
		librarian-lesson-storage librarian-lesson-validate librarian-config \
		librarian-author-key librarian-lesson-review librarian-lesson-rubric \
		librarian-lesson-judge librarian-lesson-promote librarian-lesson-transform \
		librarian-lesson-auto; do
		# shellcheck disable=SC1091
		source "${PLUGIN_ROOT}/scripts/lib/${lib}.sh"
	done
	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/lesson-auto.git
	PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
	[ -n "$PROJECT_KEY" ]
	LESSONS_DIR="${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons"
	librarian_lesson_storage_init "$PROJECT_KEY"
	librarian_config_load "$PROJECT_REPO"
}

# Seeds one PARKED pending proposal and prints its id.
_seed_pending_unscoped() {
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "$(_unscoped)")" "01M3B87J7046SJE5BECNMP670K"
}

# A pending proposal with a bound version range — not parked, so auto-confirm
# has nothing to assert.
_seed_pending() {
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "$(_versioned)")" "01KZ45MKAM734ZS7JK24D2DK0R"
}

# _seed_pending_unscoped with the marker spliced into the candidate's claim, so
# the stubbed `claude` can select a branch on it.
_seed_pending_unscoped_marked() {
	local marker="$1"
	local candidate
	candidate=$(_candidate "$(_unscoped)" | jq -c --arg m "$marker" '.claim = .claim + " " + $m')
	librarian_lesson_write_proposal "$PROJECT_KEY" "$candidate" "01M3B87J7046SJE5BECNMP670K"
}

# _seed_pending_unscoped with a different artifact id, so two proposals can
# coexist without colliding on the same source artifact.
_seed_pending_unscoped_other() {
	librarian_lesson_write_proposal "$PROJECT_KEY" \
		"$(_candidate "$(_unscoped)")" "01M3B87J7046SJE5BECNMP671Z"
}

@test "confirm records asserted_by human by default" {
	_auto_setup
	id=$(_seed_pending_unscoped)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version"
	jq -e '.asserted_by == "human"' "${LESSONS_DIR}/proposals/${id}.json"
}

@test "confirm records asserted_by model when told" {
	_auto_setup
	id=$(_seed_pending_unscoped)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" org "holds regardless of version" model
	jq -e '.asserted_by == "model"' "${LESSONS_DIR}/proposals/${id}.json"
	jq -e '.candidate.applies_to.scope.kind == "version_independent"
	   and (.candidate.applies_to.scope | has("versions") | not)' \
		"${LESSONS_DIR}/proposals/${id}.json"
}

@test "rubric selection is unchanged for a human assertion" {
	_auto_setup
	run librarian_lesson_rubric_id_for_visibility public
	[ "$output" = "lesson-promotion-public" ]
	run librarian_lesson_rubric_id_for_visibility org
	[ "$output" = "lesson-promotion" ]
	run librarian_lesson_rubric_id_for_visibility public human
	[ "$output" = "lesson-promotion-public" ]
}

@test "a model assertion selects the auto rubric at every tier" {
	_auto_setup
	run librarian_lesson_rubric_id_for_visibility public model
	[ "$output" = "lesson-promotion-public-auto" ]
	# org omits disclosure entirely, which does not hold once nobody is present.
	run librarian_lesson_rubric_id_for_visibility org model
	[ "$output" = "lesson-promotion-public-auto" ]
}

@test "private runs no jury even for a model assertion" {
	_auto_setup
	run librarian_lesson_rubric_id_for_visibility private model
	[ -z "$output" ]
}

@test "the auto rubric is defined and strictly harder than the public one" {
	_auto_setup
	auto=$(librarian_lesson_rubric_get lesson-promotion-public-auto)
	[ -n "$auto" ]
	human=$(librarian_lesson_rubric_get lesson-promotion-public)
	# Same criteria and weights, every floor at least as high, threshold higher.
	[ "$(printf '%s' "$auto" | jq -c '[.criteria[] | {name, weight}] | sort_by(.name)')" \
	  = "$(printf '%s' "$human" | jq -c '[.criteria[] | {name, weight}] | sort_by(.name)')" ]
	printf '%s' "$auto" | jq -e '.score_threshold == 0.85'
	printf '%s' "$auto" | jq -e '[.criteria[] | .min_pass] | min >= 0.7'
	printf '%s' "$auto" | jq -e '.judge_types | sort == ["adversarial","standard"]'
}

@test "a model-asserted lesson is rejected at a score the human floor would pass" {
	_auto_setup
	id=$(_seed_pending_unscoped)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" public "holds regardless of version" model
	# scope_accuracy 0.75 clears the human floor (0.70) and fails the model one (0.80).
	verdicts='[{"score":0.9,"passed":true,"judge_type":"standard","criterion_scores":{"grounding":0.9,"scope_accuracy":0.75,"generality":0.9,"disclosure":0.99}},
	           {"score":0.9,"passed":true,"judge_type":"adversarial","criterion_scores":{"grounding":0.9,"scope_accuracy":0.75,"generality":0.9,"disclosure":0.99}}]'
	run librarian_lesson_judge "$PROJECT_KEY" "$id" "$verdicts"
	[ "$status" -eq 0 ]
	jq -e '.status == "rejected" and .verdict.failed_criterion == "scope_accuracy"' \
		"${LESSONS_DIR}/proposals/${id}.json"
}

# ----------------------------------------------------------------------------
# Task 5: auto-confirm — the model writes the version-independence
# justification instead of a human.
# ----------------------------------------------------------------------------

_auto_stub() {
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
if [[ "$prompt" == *"refuse-justification"* ]]; then
  printf '%s' 'REFUSE'
elif [[ "$prompt" == *"why this lesson holds regardless of version"* ]]; then
  printf '%s' 'The failure is a property of the exec boundary, not of any release.'
else
  printf '%s' ''
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

@test "auto_justify returns a one-line justification" {
	_auto_setup; _auto_stub
	run librarian_lesson_auto_justify "$(_candidate "$(_unscoped)")"
	[ "$status" -eq 0 ]
	[[ "$output" == *"exec boundary"* ]]
	[ "$(printf '%s' "$output" | wc -l | tr -d ' ')" -le 1 ]
}

@test "auto_confirm_one confirms a parked candidate as model-asserted" {
	_auto_setup; _auto_stub
	id=$(_seed_pending_unscoped)
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	[ "$output" = "confirmed:${id}" ]
	jq -e '.status == "confirmed" and .asserted_by == "model"
	   and .candidate.applies_to.scope.kind == "version_independent"' \
		"${LESSONS_DIR}/proposals/${id}.json"
}

@test "a refusal leaves the candidate pending for a human and writes no decline" {
	_auto_setup; _auto_stub
	id=$(_seed_pending_unscoped_marked "refuse-justification")
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:no_justification" ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
	[ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "an empty model response is infrastructure, not a verdict" {
	_auto_setup; _auto_stub
	rm -f "${STUB_BIN}/claude"
	id=$(_seed_pending_unscoped)
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
}

@test "auto_confirm_one refuses a candidate that is not parked" {
	_auto_setup; _auto_stub
	id=$(_seed_pending)   # versioned scope, needs no justification
	run librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	[ "$output" = "skipped:not_parked" ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
}

# ----------------------------------------------------------------------------
# Task 6: auto-jury — dispatch the named judges from bash, and the stage
# driver that runs unattended from the worker.
# ----------------------------------------------------------------------------

# Extend the stub to answer as each judge. `--agent` is how the judge is
# selected, and the stub sees it in its own argv, not in the prompt — so it
# must branch on "$@".
_jury_stub() {
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
agent=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--agent" ]]; then j=$((i + 1)); agent="${!j}"; fi
done
prompt=$(cat)
pass='{"score":0.93,"passed":true,"judge_type":"TYPE","feedback_summary":"ok","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.85,"disclosure":0.97}}'
fail='{"score":0.6,"passed":false,"judge_type":"TYPE","feedback_summary":"no","criterion_scores":{"grounding":0.5,"scope_accuracy":0.4,"generality":0.5,"disclosure":0.97}}'
case "$agent" in
  tribunal-judge-standard)    printf '%s' "${pass//TYPE/standard}" ;;
  tribunal-judge-adversarial)
    if [[ "$prompt" == *"adversary-fails"* ]]; then printf '%s' "${fail//TYPE/adversarial}"
    else printf '%s' "${pass//TYPE/adversarial}"; fi ;;
  *) printf '%s' 'The failure is a property of the exec boundary, not of any release.' ;;
esac
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

@test "auto_judge_one promotes a candidate both judges pass" {
	_auto_setup; _jury_stub
	id=$(_seed_pending_unscoped)
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	run librarian_lesson_auto_judge_one "$PROJECT_KEY" "$id"
	[ "$status" -eq 0 ]
	[ "$output" = "judged:${id}" ]
	jq -e '.status == "approved"' "${LESSONS_DIR}/proposals/${id}.json"
	# Model-asserted, so it is held rather than shipped (Task 1).
	[ -f "${LESSONS_DIR}/approved_held/${id}.json" ]
	[ ! -f "${LESSONS_DIR}/approved/${id}.json" ]
}

@test "auto_judge_one records a rejection when the adversary fails it" {
	_auto_setup; _jury_stub
	id=$(_seed_pending_unscoped_marked "adversary-fails")
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	run librarian_lesson_auto_judge_one "$PROJECT_KEY" "$id"
	[ "$output" = "judged:${id}" ]
	jq -e '.status == "rejected"' "${LESSONS_DIR}/proposals/${id}.json"
	[ ! -f "${LESSONS_DIR}/approved_held/${id}.json" ]
}

@test "a judge returning nothing leaves the candidate confirmed for a retry" {
	_auto_setup; _jury_stub
	id=$(_seed_pending_unscoped)
	librarian_lesson_auto_confirm_one "$PROJECT_KEY" "$id"
	rm -f "${STUB_BIN}/claude"
	run librarian_lesson_auto_judge_one "$PROJECT_KEY" "$id"
	[ "$output" = "unavailable" ]
	jq -e '.status == "confirmed"' "${LESSONS_DIR}/proposals/${id}.json"
	[ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

@test "the worker runs no auto stage when lesson_auto is disabled" {
	_auto_setup; _jury_stub
	mkdir -p "${PROJECT_REPO}/.claude"
	printf '%s\n' '{"librarian":{"lesson_auto":{"enabled":false}}}' \
		> "${PROJECT_REPO}/.claude/settings.json"
	librarian_config_load "$PROJECT_REPO"
	id=$(_seed_pending_unscoped)
	run librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	jq -e '.status == "pending"' "${LESSONS_DIR}/proposals/${id}.json"
}

# The cap tests exactly what the brief's own assertions would not have caught:
# `-le 2` / `-ge 1` pass even if the cap did nothing at all. With
# max_juries_per_scan=1 and two parked candidates, auto_stage auto-confirms
# BOTH (confirm is not capped — only the jury is), then juries exactly ONE.
@test "the jury cap stops after N candidates and declines nothing" {
	_auto_setup; _jury_stub
	mkdir -p "${PROJECT_REPO}/.claude"
	printf '%s\n' '{"librarian":{"lesson_auto":{"enabled":true,"max_juries_per_scan":1}}}' \
		> "${PROJECT_REPO}/.claude/settings.json"
	librarian_config_load "$PROJECT_REPO"
	a=$(_seed_pending_unscoped); b=$(_seed_pending_unscoped_other)
	run librarian_lesson_auto_stage "$PROJECT_KEY"
	[ "$status" -eq 0 ]
	# Exactly one proposal reached a jury and got a terminal verdict.
	[ "$(jq -r -s '[.[] | select(.status == "approved" or .status == "rejected")] | length' \
		"${LESSONS_DIR}/proposals/"*.json)" -eq 1 ]
	# Exactly one is still confirmed, capped out for the next scan.
	[ "$(jq -r -s '[.[] | select(.status == "confirmed")] | length' \
		"${LESSONS_DIR}/proposals/"*.json)" -eq 1 ]
	# Cost control must never write a decline — a decline is terminal
	# (librarian_lesson_seen reads that file), so capping the jury must not
	# look like judging the candidate that never reached one.
	[ ! -f "${LESSONS_DIR}/declined.jsonl" ]
}

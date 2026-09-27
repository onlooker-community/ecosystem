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

_auto_setup() {
	for lib in librarian-project-key librarian-ulid librarian-storage \
		librarian-lesson-storage librarian-lesson-validate librarian-config \
		librarian-author-key librarian-lesson-review librarian-lesson-rubric \
		librarian-lesson-judge; do
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

#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git

	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-rubric.sh"
	librarian_config_load "$PROJECT_REPO"

	PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")
}

@test "org visibility selects the lesson-promotion rubric" {
	run librarian_lesson_rubric_id_for_visibility "org"
	[ "$status" -eq 0 ]
	[ "$output" = "lesson-promotion" ]
}

@test "public visibility selects the public rubric" {
	run librarian_lesson_rubric_id_for_visibility "public"
	[ "$status" -eq 0 ]
	[ "$output" = "lesson-promotion-public" ]
}

@test "private visibility selects no rubric" {
	run librarian_lesson_rubric_id_for_visibility "private"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "an unknown visibility is refused" {
	run librarian_lesson_rubric_id_for_visibility "everyone"
	[ "$status" -ne 0 ]
}

@test "the org rubric gates on majority and the public rubric on unanimous" {
	local org public
	org=$(librarian_lesson_rubric_get "lesson-promotion")
	public=$(librarian_lesson_rubric_get "lesson-promotion-public")
	[ "$(printf '%s' "$org" | jq -r '.gate_policy')" = "majority" ]
	[ "$(printf '%s' "$public" | jq -r '.gate_policy')" = "unanimous" ]
}

@test "both rubrics carry a 0.75 score threshold and two judge types" {
	local r
	for r in lesson-promotion lesson-promotion-public; do
		local got
		got=$(librarian_lesson_rubric_get "$r")
		[ "$(printf '%s' "$got" | jq -r '.score_threshold')" = "0.75" ]
		[ "$(printf '%s' "$got" | jq -c '.judge_types')" = '["standard","adversarial"]' ]
	done
}

@test "neither rubric carries a max_iterations knob" {
	# There is no Actor in this pipeline, so a retry setting would be a knob
	# that cannot do anything. See the spec's "There is no Actor" section.
	local r
	for r in lesson-promotion lesson-promotion-public; do
		local got
		got=$(librarian_lesson_rubric_get "$r")
		[ "$(printf '%s' "$got" | jq 'has("max_iterations")')" = "false" ]
	done
}

@test "each rubric's criterion weights sum to exactly 1.00" {
	# Tribunal validates each weight in [0,1] but never their total. An
	# unnormalized set would silently mis-score the moment ecosystem-pht
	# implements real weighted_mean.
	local r
	for r in lesson-promotion lesson-promotion-public; do
		local sum
		sum=$(librarian_lesson_rubric_get "$r" | jq '[.criteria[].weight] | add | . * 100 | round')
		[ "$sum" -eq 100 ]
	done
}

@test "only the public rubric carries the disclosure criterion" {
	local org public
	org=$(librarian_lesson_rubric_get "lesson-promotion" | jq -c '[.criteria[].name]')
	public=$(librarian_lesson_rubric_get "lesson-promotion-public" | jq -c '[.criteria[].name]')
	[ "$org" = '["grounding","scope_accuracy","generality"]' ]
	[ "$public" = '["grounding","scope_accuracy","generality","disclosure"]' ]
}

@test "disclosure carries the highest floor of any criterion" {
	local r floor others_max
	r=$(librarian_lesson_rubric_get "lesson-promotion-public")
	floor=$(printf '%s' "$r" | jq '.criteria[] | select(.name == "disclosure") | .min_pass')
	others_max=$(printf '%s' "$r" | jq '[.criteria[] | select(.name != "disclosure") | .min_pass] | max')
	[ "$floor" = "0.9" ] || return 1
	[ "$(jq -n --argjson a "$floor" --argjson b "$others_max" '$a > $b')" = "true" ] || return 1
}

@test "an unknown rubric id is refused and echoes nothing" {
	run librarian_lesson_rubric_get "no-such-rubric"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
}

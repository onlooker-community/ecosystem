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

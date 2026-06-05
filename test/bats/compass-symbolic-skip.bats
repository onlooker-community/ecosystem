#!/usr/bin/env bats

# Covers the symbolic skip layer: cheap pattern check that short-circuits
# to a pass when the prior assistant turn is an enumerated question and
# the current context is a clean option reference. See ADR-001.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/compass"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	# Source the libs the gate depends on so _compass_symbolic_skip is in scope.
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-config.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-events.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-sanitizer.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-transcript.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-evaluator.sh"
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/compass-gate.sh"
}

@test "skips when prior turn is enumerated question and reply is an ordinal" {
	local prior='Which API should we touch?
1. the internal one
2. the public one'
	run _compass_symbolic_skip "$prior" "the first one"
	[ "$status" -eq 0 ]
}

@test "skips on a bare digit option reference" {
	local prior='1. test_one
2. test_two
Which one?'
	run _compass_symbolic_skip "$prior" "2"
	[ "$status" -eq 0 ]
}

@test "skips on a clean affirmation" {
	local prior='1. left
2. right
which side?'
	run _compass_symbolic_skip "$prior" "both"
	[ "$status" -eq 0 ]
}

@test "does NOT skip when the prior turn has no enumerated list" {
	local prior='Should we proceed with the refactor?'
	run _compass_symbolic_skip "$prior" "yes"
	[ "$status" -ne 0 ]
}

@test "does NOT skip when the prior turn has no question mark" {
	local prior='Here are the options:
1. A
2. B'
	run _compass_symbolic_skip "$prior" "1"
	[ "$status" -ne 0 ]
}

@test "does NOT skip when prior turn is empty" {
	run _compass_symbolic_skip "" "yes"
	[ "$status" -ne 0 ]
}

@test "does NOT skip on a hedged affirmation (qualifier clause present)" {
	skip "hedged-qualifier rejection not yet implemented in _compass_symbolic_skip"
	local prior='1. delete now
2. archive first
Which one?'
	# A qualifier clause means the reply is not a clean option reference.
	run _compass_symbolic_skip "$prior" "both, but only if it's easy"
	[ "$status" -ne 0 ]
}

@test "does NOT skip on a free-form reply with no option shape" {
	local prior='1. one
2. two
Pick?'
	run _compass_symbolic_skip "$prior" "Actually I think we should refactor the whole thing"
	[ "$status" -ne 0 ]
}

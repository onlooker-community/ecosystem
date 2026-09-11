#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

	source "${PLUGIN_ROOT}/scripts/lib/librarian-durability.sh"

	# Long enough to clear the 40-char detail gate, and containing "because" —
	# one of the thirteen marker phrases config.json ships. Any correctly
	# configured run keeps this artifact, so a drop always means the markers
	# never arrived rather than that the content was thin.
	DURABLE='[{"id":"a1","summary":"We chose the queue","detail":"We chose the queue because the old path dropped events on every restart."}]'
}

@test "an empty marker list is reported as a fault, not as a missing marker" {
	# The allowlist inverts when it is empty: matches_any([]) is false for every
	# artifact, so each one falls to the else branch. Reporting that as
	# filter_marker_missing makes a total configuration failure indistinguishable
	# from ordinary non-durable content — which is how a real 3,837-drop outage
	# went unnoticed for two months (ecosystem-449.48). An empty allowlist is
	# never a statement about the artifact.
	run librarian_durability_filter "$DURABLE" '[]' 40
	[ "$status" -eq 0 ]

	local reason
	reason=$(printf '%s' "$output" | jq -r '.dropped[0].reason')
	[ "$reason" = "filter_markers_unavailable" ]
}

@test "a real marker list still rejects an artifact that misses every marker" {
	# The genuine verdict has to survive the fix. If filter_marker_missing ever
	# stopped being reachable, the new reason would just be the old bug wearing
	# a different name.
	local thin='[{"id":"a2","summary":"ran the suite","detail":"Ran the suite again this morning and everything went green on the first try."}]'
	run librarian_durability_filter "$thin" '["because","never"]' 40
	[ "$status" -eq 0 ]

	local reason
	reason=$(printf '%s' "$output" | jq -r '.dropped[0].reason')
	[ "$reason" = "filter_marker_missing" ]
}

@test "a real marker list still keeps an artifact that matches one" {
	run librarian_durability_filter "$DURABLE" '["because","never"]' 40
	[ "$status" -eq 0 ]

	[ "$(printf '%s' "$output" | jq '.kept | length')" -eq 1 ]
	[ "$(printf '%s' "$output" | jq '.dropped | length')" -eq 0 ]
}

@test "an empty marker list does not hijack the length gate" {
	# This is why the check sits in the else branch rather than at the top of
	# classify: detail_too_short is a true statement about the artifact and is
	# reachable without consulting the markers at all. Hoisting the
	# markers-unavailable test above it would relabel honest verdicts as
	# configuration faults and lose the length signal.
	local short='[{"id":"a3","summary":"fixed it","detail":"too short"}]'
	run librarian_durability_filter "$short" '[]' 40
	[ "$status" -eq 0 ]

	local reason
	reason=$(printf '%s' "$output" | jq -r '.dropped[0].reason')
	[ "$reason" = "detail_too_short" ]
}

@test "an omitted marker argument reads the same as an empty one" {
	# The call site is MARKERS_JSON=$(librarian_config_get ...), and bash's :-
	# substitutes on empty as well as unset. A config read that returns nothing
	# therefore arrives here as "" and defaults to []. Both spellings have to
	# reach the fault, or the fix misses the exact path the outage took.
	run librarian_durability_filter "$DURABLE" "" 40
	[ "$status" -eq 0 ]

	local reason
	reason=$(printf '%s' "$output" | jq -r '.dropped[0].reason')
	[ "$reason" = "filter_markers_unavailable" ]
}

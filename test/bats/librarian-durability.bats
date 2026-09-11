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

@test "every drop reason the filter can produce survives the emitter" {
	# Reconciles the reason literals in the source against the payload contract,
	# rather than pinning one example. filter_drop_pattern spent the whole life
	# of the drop list outside the enum (ecosystem-449.56): the emitter is
	# fail-soft, so under ONLOOKER_VALIDATE it refused the event and discarded
	# it, and no test could assert on a drop-pattern drop because the event never
	# landed while the suite was running. A reason added here but not to the
	# schema is invisible in exactly the place the suites look, so this fails at
	# the next divergence instead of going quiet.
	local reasons
	reasons=$(grep -oE 'kept: false, reason: "[a-z_]+"' \
		"${PLUGIN_ROOT}/scripts/lib/librarian-durability.sh" \
		| sed 's/.*"\(.*\)"/\1/' | sort -u)
	[ -n "$reasons" ]

	source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
	# setup_test_env deliberately unsets this so a developer's real log cannot be
	# written to; validate-path.sh would derive it, but naming it here keeps the
	# test from depending on that whole chain.
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	export _LIBRARIAN_EVENT_JS="${REPO_ROOT}/scripts/lib/onlooker-event.mjs"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	local reason
	for reason in $reasons; do
		: >"$ONLOOKER_EVENTS_LOG"
		ONLOOKER_VALIDATE=1 librarian_emit "librarian.candidate.dropped" \
			"sess-reason-check" "{\"reason\":\"${reason}\"}"
		# An empty log means validation refused it — the silent path this guards.
		if ! grep -q "\"reason\":\"${reason}\"" "$ONLOOKER_EVENTS_LOG"; then
			echo "reason '${reason}' is emitted by librarian_durability_filter" >&2
			echo "but refused by the librarian.candidate.dropped payload contract" >&2
			echo "in @onlooker-community/schema — add it to the enum there" >&2
			return 1
		fi
	done
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

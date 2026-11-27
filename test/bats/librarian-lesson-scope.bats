#!/usr/bin/env bats
# D4 and D5: turning what Observe read into a scope. Pure jq, no I/O.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	source "${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-lesson-scope.sh"
	source "${REPO_ROOT}/plugins/librarian/scripts/lib/librarian-lesson-validate.sh"
}

_range() { librarian_lesson_range_for_version "$1"; }

@test "a 1.x-or-later version covers the rest of its major" {
	[ "$(_range 5.4.21)" = ">=5.4.21 <6" ] || return 1
	[ "$(_range 26.1)" = ">=26.1 <27" ]
}

@test "a 0.x version covers the rest of its minor" {
	[ "$(_range 0.27.0)" = ">=0.27.0 <0.28" ] || return 1
	[ "$(_range 0.0.3)" = ">=0.0.3 <0.1" ]
}

@test "a caret range and a v prefix read as the version they start at" {
	[ "$(_range ^18.2.0)" = ">=18.2.0 <19" ] || return 1
	[ "$(_range v22.11.0)" = ">=22.11.0 <23" ]
}

@test "a version that is not at least X.Y gets no range" {
	for v in 20200816 4 latest "~5.4" ">=1" 1.0.0-beta.3 c2a87611d0e1; do
		[ -z "$(_range "$v")" ] || return 1
	done
}

@test "every range it makes passes the transform's range rule" {
	for v in 5.4.21 26.1 0.27.0 0.0.3 ^18.2.0 v22.11.0 1.0; do
		librarian_lesson_valid_range "$(_range "$v")" || return 1
	done
}

_scope() { librarian_lesson_scope_from_observation "$1" "$2"; }

@test "an empty stack is no_stack, whatever was observed" {
	[ "$(_scope '[]' '{"observed_on":{},"unresolved":[]}')" = '{"kind":"no_stack"}' ]
}

@test "a stack with a rangeable observation is versioned, on that entry only" {
	out=$(_scope '["vite","Sentry"]' '{"observed_on":{"vite":{"version":"5.4.21","source":"lockfile","basis":"session_commit"}},"unresolved":["Sentry"]}')
	[ "$out" = '{"kind":"versioned","versions":{"vite":">=5.4.21 <6"}}' ]
}

@test "an unrangeable observation stays out of versions" {
	out=$(_scope '["awk","node"]' '{"observed_on":{"awk":{"version":"20200816","source":"probe","basis":"machine","flavor":"bsd"},"node":{"version":"26.1.0","source":"probe","basis":"machine"}},"unresolved":[]}')
	[ "$out" = '{"kind":"versioned","versions":{"node":">=26.1.0 <27"}}' ]
}

@test "a stack with nothing rangeable is unscoped" {
	[ "$(_scope '["Sentry"]' '{"observed_on":{},"unresolved":["Sentry"]}')" = '{"kind":"unscoped"}' ] || return 1
	[ "$(_scope '["awk"]' '{"observed_on":{"awk":{"version":"20200816","source":"probe","basis":"machine"}},"unresolved":[]}')" = '{"kind":"unscoped"}' ]
}

@test "a missing or malformed observation is unscoped, not an error" {
	run _scope '["vite"]' ''
	[ "$status" -eq 0 ] || return 1
	[ "$output" = '{"kind":"unscoped"}' ] || return 1
	run _scope '["vite"]' 'not json'
	[ "$output" = '{"kind":"unscoped"}' ]
}

@test "a non-string version on one entry does not drop the others" {
	out=$(_scope '["a","b"]' '{"observed_on":{"a":{"version":5,"source":"probe","basis":"machine"},"b":{"version":"2.1.0","source":"lockfile","basis":"head"}},"unresolved":[]}')
	[ "$out" = '{"kind":"versioned","versions":{"b":">=2.1.0 <3"}}' ]
}

@test "a non-string stack element does not drop the others" {
	out=$(_scope '[3,"b"]' '{"observed_on":{"b":{"version":"2.1.0","source":"lockfile","basis":"head"}},"unresolved":[]}')
	[ "$out" = '{"kind":"versioned","versions":{"b":">=2.1.0 <3"}}' ]
}

@test "a version too large for a number gets no range" {
	[ -z "$(_range 99999999999999999999.1)" ] || return 1
	[ -z "$(_range 0.99999999999999999999)" ]
}

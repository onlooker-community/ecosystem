#!/usr/bin/env bats
#
# Guards the payload-default expansion in every emit helper.
#
# Two tempting forms are both wrong, and each fails in a way the other does not:
#
#   "${3:-{\}}"  keeps the backslash on bash 3.2 (the bash macOS ships, and the
#                one `#!/usr/bin/env bash` resolves to there), yielding {\} —
#                invalid JSON, so the emit silently drops the event. Works on
#                bash 5.x, which is why CI never caught it.
#   "${3:-{}}"   appends a stray `}` to any payload that IS supplied, on EVERY
#                bash version, corrupting the far more common path.
#
# The brace-free form below is correct on both. This test runs the real
# expansion under the real interpreter rather than asserting on source text.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
}

_emit_libs() {
	printf '%s\n' \
		"scripts/lib/prompt-rules.sh" \
		"plugins/curator/scripts/lib/curator-emit.sh" \
		"plugins/historian/scripts/lib/historian-emit.sh" \
		"plugins/librarian/scripts/lib/librarian-emit.sh" \
		"plugins/librarian/scripts/lib/librarian-cli.sh" \
		"plugins/tribunal/scripts/lib/tribunal-gate.sh"
}

@test "no emit helper inlines braces in a parameter-expansion default" {
	# Code only — a comment explaining the hazard must not trip its own guard.
	local hits
	hits=$(cd "$REPO_ROOT" && grep -rn ':-{' --include="*.sh" scripts/ plugins/ \
		| grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
	[ -z "$hits" ]
}

@test "the brace-free default yields {} when no payload is passed" {
	local probe="${BATS_TEST_TMPDIR}/probe.sh"
	printf '%s\n' 'f() { local p="${3:-}"; [ -z "$p" ] && p='"'"'{}'"'"'; printf "%s" "$p"; }' 'f a b' >"$probe"
	run bash "$probe"
	[ "$status" -eq 0 ] && [ "$output" = '{}' ]
}

@test "the brace-free default passes a supplied payload through unchanged" {
	local probe="${BATS_TEST_TMPDIR}/probe.sh"
	printf '%s\n' 'f() { local p="${3:-}"; [ -z "$p" ] && p='"'"'{}'"'"'; printf "%s" "$p"; }' 'f a b '"'"'{"a":{"b":1}}'"'"'' >"$probe"
	run bash "$probe"
	[ "$status" -eq 0 ] && [ "$output" = '{"a":{"b":1}}' ]
}

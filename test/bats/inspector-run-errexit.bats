#!/usr/bin/env bats
#
# ONL-29 / ecosystem-449.70. inspector_run carries eight `(( x++ ))` counter
# increments, all unguarded. `(( x++ ))` evaluates to the PRE-increment value,
# so the first increment from 0 returns exit status 1 and aborts under errexit.
#
# THIS TEST MUST RUN UNDER BASH 4+. On bash 3.2 -- which is /bin/bash on macOS
# and therefore what `bats` resolves locally -- the arithmetic command does NOT
# abort under errexit, so the whole reproduction passes whether or not the bug
# is fixed. Measured both ways:
#
#   bash 3.2.57  set -e; x=0; (( x++ ))  -> SURVIVED, exit 0
#   bash 5.3.15  same                    -> exit 1, aborted
#
# That is the local-vs-CI divergence the writing-tests skill documents for the
# `[[ ]]` non-final-assertion hole, and it bites the same way here: without
# pinning the interpreter this file would report coverage it does not have.
#
# The fixture uses a check that PASSES. Under errexit inspector_run aborts
# earlier for the other outcomes -- at `command -v` for a missing tool, and at
# the `output=$(...)` assignment for a failing one -- so neither reaches a
# counter. Only a passing check gets as far as `(( ran++ ))` with ran still 0.
# 449.70's framing that "adding -e makes the counters abort on their first
# increment" is therefore incomplete: two earlier aborts stand in front of them.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/inspector"
	export ONLOOKER_EVENTS_LOG="${ONLOOKER_DIR}/logs/onlooker-events.jsonl"
	mkdir -p "$(dirname "$ONLOOKER_EVENTS_LOG")"

	FIXTURE_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "${FIXTURE_REPO}/src"
	printf 'x\n' > "${FIXTURE_REPO}/src/x.ts"
	git -C "$FIXTURE_REPO" init -q

	MODERN_BASH=""
	local candidate
	for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)"; do
		[[ -x "$candidate" ]] || continue
		if [[ "$("$candidate" -c 'printf %s "${BASH_VERSINFO[0]}"')" -ge 4 ]]; then
			MODERN_BASH="$candidate"
			break
		fi
	done
}

@test "the arithmetic-command hazard is real on this machine's bash 4+" {
	# Guards the test below: if no bash 4+ is reachable, or a future bash stops
	# failing a zero-valued arithmetic command, the reproduction would pass
	# vacuously and report coverage that does not exist.
	[[ -n "$MODERN_BASH" ]] || skip "no bash 4+ available to exercise the errexit abort"

	run "$MODERN_BASH" -c 'set -e; x=0; (( x++ )); printf SURVIVED'
	[ "$status" -eq 1 ] || return 1
	[ -z "$output" ]
}

@test "inspector_run survives its first counter increment under errexit" {
	[[ -n "$MODERN_BASH" ]] || skip "no bash 4+ available to exercise the errexit abort"

	run "$MODERN_BASH" -c '
		set -euo pipefail
		PLUGIN_ROOT="'"$PLUGIN_ROOT"'"
		export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
		export INSPECTOR_FILE="'"${FIXTURE_REPO}"'/src/x.ts"
		export INSPECTOR_FILE_RELATIVE="src/x.ts"
		export INSPECTOR_REPO_ROOT="'"${FIXTURE_REPO}"'"
		export INSPECTOR_PROJECT_KEY="testkey00000"
		export INSPECTOR_TOOL_NAME="Edit"
		source "$PLUGIN_ROOT/scripts/lib/inspector-config.sh"
		source "$PLUGIN_ROOT/scripts/lib/inspector-events.sh"
		source "$PLUGIN_ROOT/scripts/lib/inspector-run.sh"
		set -e
		inspector_run '"'"'[{"name":"t","kind":"lint","argv":["true"]}]'"'"' >/dev/null
		printf "SENTINEL\n"
	'
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"SENTINEL"* ]]
}

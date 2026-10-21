#!/usr/bin/env bash
# Fails when a bats TAP report ran fewer tests than it planned (ONL-109).
#
# bats reports that mismatch only as a trailing "# bats warning: Executed N
# instead of expected M" and still exits 0. A duplicated target under -j is one
# way to produce it: the file is planned twice and run once, so a failing file
# can disappear from a green run. run-bats.sh refuses overlapping targets up
# front; this is the backstop for any other route to the same mismatch.
#
# Usage: scripts/test/check-bats-plan.sh <report.tap>
set -uo pipefail

report="${1:?usage: check-bats-plan.sh <report.tap>}"

if [[ ! -r "$report" ]]; then
	echo "check-bats-plan: no report at ${report}" >&2
	exit 1
fi

planned=$(sed -nE 's/^1\.\.([0-9]+).*/\1/p' "$report" | head -n 1)
if [[ -z "$planned" ]]; then
	echo "check-bats-plan: no plan line in ${report}" >&2
	exit 1
fi

# "ok N # skip" is a test that ran and chose to skip; it counts as run.
ran=$(grep -cE '^(not )?ok [0-9]+' "$report")

if ((ran != planned)); then
	echo "check-bats-plan: bats ran ${ran} of ${planned} planned tests -- a test that never ran is not a pass" >&2
	exit 1
fi

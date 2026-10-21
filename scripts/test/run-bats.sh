#!/usr/bin/env bash
# Runs the bats suite with emission reporting, then writes the completion
# sentinel that check-bus-coverage.mjs requires.
#
# The sentinel exists because the coverage gate has a precondition nothing used
# to enforce: one COMPLETE, uncontended suite must have produced the report. Two
# agents running the suite in one checkout clobber each other -- this script
# opens with `rm -rf` on a shared path and every run appends to the same
# emissions.jsonl -- and the gate then reported a wall of "expected type never
# emitted" that reads exactly like a real coverage regression. Stamping each
# emission with a run id, and writing complete.json only once bats returns, lets
# the gate say which of the two actually happened. See ecosystem-0bh.
#
# Usage: scripts/test/run-bats.sh [bats args...]   (default target: test/bats)
#
# Explicit targets REPLACE the default rather than adding to it, which is why
# package.json names no target. `npm run test:bats -- test/bats/foo.bats` used to
# become `bats test/bats test/bats/foo.bats`; under -j bats then plans that file
# twice, runs it once, and exits 0 -- a failing file vanished from a green run
# (ONL-109). Overlapping targets are refused below, and check-bats-plan.sh fails
# any run that executed fewer tests than it planned.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REPORT_DIR="${ONLOOKER_TEST_REPORT_DIR:-${REPO_ROOT}/test/tmp-emission-report}"

# Physical path of a target, so `dir/a.bats` and `dir/./a.bats` compare equal.
_canonical() {
	if [[ -d "$1" ]]; then
		(cd "$1" && pwd -P)
	else
		printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
	fi
}

# Collect the path targets, stepping over the values of bats options that take
# one -- `--output <dir>` names a directory that is not a target.
targets=()
skip_next=0
for arg in "$@"; do
	if ((skip_next)); then
		skip_next=0
		continue
	fi
	case "$arg" in
	-f | --filter | -F | --formatter | -j | --jobs | -o | --output | \
		--report-formatter | --filter-status | --filter-tags | \
		--code-quote-style | --line-reference-format | \
		--gather-test-outputs-in | --setup-suite-file)
		skip_next=1
		;;
	-*) ;;
	*) [[ -e "$arg" ]] && targets+=("$(_canonical "$arg")") ;;
	esac
done

# Refused before the report directory is touched, so an earlier run's report
# survives and no completion sentinel claims a suite that never ran.
for ((i = 0; i < ${#targets[@]}; i++)); do
	for ((j = 0; j < ${#targets[@]}; j++)); do
		((i == j)) && continue
		a="${targets[i]}" b="${targets[j]}"
		if [[ "$a" == "$b" || "$b" == "$a"/* ]]; then
			echo "run-bats: targets overlap: ${b} is already covered by ${a}." >&2
			echo "run-bats: bats would plan it twice and run it once under -j; pass only one." >&2
			exit 2
		fi
	done
done

# Distinct per run, which is all the gate compares. Not an event id, so the
# repo's ULID convention does not apply; the PID keeps concurrent runs apart.
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

rm -rf "$REPORT_DIR"
mkdir -p "$REPORT_DIR"

# BATS_JOBS=1 runs bats with no -j at all, not `-j 1`: -j routes through GNU
# parallel either way, and avoiding that dependency is the point of serial mode.
jobs=("-j" "${BATS_JOBS:-4}" "--no-parallelize-within-files")
[[ "${BATS_JOBS:-4}" == "1" ]] && jobs=()

status=0
ONLOOKER_VALIDATE=1 \
	ONLOOKER_TEST_REPORT_DIR="$REPORT_DIR" \
	ONLOOKER_TEST_RUN_ID="$RUN_ID" \
	bats "${jobs[@]+"${jobs[@]}"}" "${@:-test/bats}" \
	--report-formatter tap --output "$REPORT_DIR" || status=$?

# A green run that skipped planned tests is not green.
if ((status == 0)); then
	"${REPO_ROOT}/scripts/test/check-bats-plan.sh" "${REPORT_DIR}/report.tap" || status=1
fi

# Written last and only on return: an interrupted or killed suite leaves no
# sentinel, which is exactly the "did not finish" the gate needs to see.
printf '{"run_id":"%s","completed_at":"%s","bats_status":%d}\n' \
	"$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" \
	>"${REPORT_DIR}/complete.json"

exit "$status"

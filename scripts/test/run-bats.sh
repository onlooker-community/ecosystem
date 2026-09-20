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
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REPORT_DIR="${ONLOOKER_TEST_REPORT_DIR:-${REPO_ROOT}/test/tmp-emission-report}"

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
	bats "${jobs[@]+"${jobs[@]}"}" "${@:-test/bats}" || status=$?

# Written last and only on return: an interrupted or killed suite leaves no
# sentinel, which is exactly the "did not finish" the gate needs to see.
printf '{"run_id":"%s","completed_at":"%s","bats_status":%d}\n' \
	"$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$status" \
	>"${REPORT_DIR}/complete.json"

exit "$status"

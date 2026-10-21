#!/usr/bin/env bats
# The suite runner must never let a skipped test read as a pass (ONL-109).
#
# `npm run test:bats -- test/bats/foo.bats` used to expand to
# `bats ... test/bats test/bats/foo.bats`. Under -j, bats plans the file twice,
# runs it once, prints "Executed N instead of expected M" and exits 0 -- so a
# genuinely failing file could vanish from a green run.
#
# Every nested run points ONLOOKER_TEST_REPORT_DIR at a temp dir. The runner
# opens with `rm -rf` on that path, and the default is the outer suite's own
# report, which the bus-coverage gate reads after this file finishes.

setup() {
	# The npm test below would run the whole suite -- this file included -- if
	# the script ever went back to naming test/bats itself. Stop the recursion
	# there; the outer copy of that test still fails on the unexpected output.
	[[ -z "${RUN_BATS_TARGETS_NESTED:-}" ]] || skip "nested inside run-bats-targets"

	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	RUNNER="${REPO_ROOT}/scripts/test/run-bats.sh"
	PLAN_CHECK="${REPO_ROOT}/scripts/test/check-bats-plan.sh"
	export ONLOOKER_TEST_REPORT_DIR="${BATS_TEST_TMPDIR}/report"

	FX="${BATS_TEST_TMPDIR}/fx"
	mkdir -p "$FX"
	printf '@test "pass one" { true; }\n@test "pass two" { true; }\n' >"${FX}/pass.bats"
	printf '@test "fails" { false; }\n' >"${BATS_TEST_TMPDIR}/failing.bats"
}

@test "a file under a directory target is refused before anything runs" {
	run "$RUNNER" "$FX" "${FX}/pass.bats"

	[ "$status" -eq 2 ] || return 1
	[[ "$output" == *"overlap"* ]] || return 1
	[[ "$output" != *"ok 1"* ]] || return 1
	# A refused run must not leave a completion sentinel the coverage gate
	# would read as a finished suite.
	[ ! -e "${ONLOOKER_TEST_REPORT_DIR}/complete.json" ]
}

@test "the same file given twice is refused" {
	run "$RUNNER" "${FX}/pass.bats" "${FX}/./pass.bats"

	[ "$status" -eq 2 ] || return 1
	[[ "$output" == *"overlap"* ]]
}

@test "a refused run leaves an earlier report in place" {
	mkdir -p "$ONLOOKER_TEST_REPORT_DIR"
	printf 'earlier\n' >"${ONLOOKER_TEST_REPORT_DIR}/emissions.jsonl"

	run "$RUNNER" "$FX" "${FX}/pass.bats"

	[ "$status" -eq 2 ] || return 1
	[ -f "${ONLOOKER_TEST_REPORT_DIR}/emissions.jsonl" ]
}

@test "an option value is not mistaken for an overlapping target" {
	run "$RUNNER" --filter pass "${FX}/pass.bats" --output "$FX"

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"pass one"* ]]
}

@test "a failing file named on its own fails the run" {
	run "$RUNNER" "${BATS_TEST_TMPDIR}/failing.bats"

	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"not ok 1 fails"* ]]
}

@test "the npm script runs only the file it is given" {
	cd "$REPO_ROOT"
	RUN_BATS_TARGETS_NESTED=1 run npm run --silent test:bats -- "${BATS_TEST_TMPDIR}/failing.bats"

	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"not ok 1 fails"* ]] || return 1
	# Exact line: a substring match would accept the full suite's "1..1880".
	printf '%s\n' "$output" | grep -qx '1\.\.1'
}

@test "the plan check passes when every planned test ran" {
	printf '1..2\nok 1 a\nnot ok 2 b\n# detail\n' >"${BATS_TEST_TMPDIR}/r.tap"

	run "$PLAN_CHECK" "${BATS_TEST_TMPDIR}/r.tap"

	[ "$status" -eq 0 ]
}

@test "the plan check counts skipped tests as run" {
	printf '1..2\nok 1 a\nok 2 b # skip not here\n' >"${BATS_TEST_TMPDIR}/r.tap"

	run "$PLAN_CHECK" "${BATS_TEST_TMPDIR}/r.tap"

	[ "$status" -eq 0 ]
}

@test "the plan check fails when fewer tests ran than were planned" {
	printf '1..8\nok 1 a\nok 2 b\nok 3 c\n' >"${BATS_TEST_TMPDIR}/r.tap"

	run "$PLAN_CHECK" "${BATS_TEST_TMPDIR}/r.tap"

	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"3 of 8"* ]]
}

@test "the plan check fails on a report with no plan line" {
	printf 'ok 1 a\n' >"${BATS_TEST_TMPDIR}/r.tap"

	run "$PLAN_CHECK" "${BATS_TEST_TMPDIR}/r.tap"

	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"no plan line"* ]]
}

@test "the runner fails a green run whose report shows a skipped test" {
	# Drive the backstop through the runner itself, not just the helper: a
	# stub bats that passes but under-reports is exactly the shape bats
	# produced for a duplicated target under -j.
	local stub="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$stub"
	cat >"${stub}/bats" <<'STUB'
#!/usr/bin/env bash
out=""
while (($#)); do
	case "$1" in
	-o | --output) out="$2"; shift 2 ;;
	*) shift ;;
	esac
done
printf '1..3\nok 1 a\nok 2 b\n' >"${out}/report.tap"
printf 'ok 1 a\nok 2 b\n'
exit 0
STUB
	chmod +x "${stub}/bats"

	PATH="${stub}:${PATH}" run "$RUNNER" "${FX}/pass.bats"

	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"2 of 3"* ]] || return 1
	jq -e '.bats_status != 0' "${ONLOOKER_TEST_REPORT_DIR}/complete.json" >/dev/null
}

#!/usr/bin/env bats

# The harness behind ONL-102.
#
# drift_threshold was 0.05, picked rather than measured, against a judge whose
# spread on identical content was recorded in-tree at 0.13-0.24 with no
# methodology attached -- no sample count, no files, no date. This script
# re-derives that number so it can be defended, and re-derived again whenever
# the prompt or the model changes, which is what makes a measured threshold
# different from a picked one.
#
# The 30 real judge calls are manual. Nothing here spends a token: the stub
# stands in for the judge so the plumbing and the arithmetic can be tested
# exhaustively. A test suite that costs 30 Haiku calls is a trap nobody runs.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	HARNESS="${PLUGIN_ROOT}/scripts/measure-judge-spread.sh"

	SUBJECT_DIR="${BATS_TEST_TMPDIR}/subjects"
	mkdir -p "$SUBJECT_DIR"
	printf '# Reviewer\n\nA well-specified agent.\n' > "${SUBJECT_DIR}/one.md"
	printf '# Auditor\n\nAnother one.\n' > "${SUBJECT_DIR}/two.md"

	OUT_DIR="${BATS_TEST_TMPDIR}/out"
	CALL_LOG="${BATS_TEST_TMPDIR}/calls"
	PROMPT_LOG="${BATS_TEST_TMPDIR}/prompts"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	# Cycles through four scores so the samples have real spread to summarize.
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat >> "${PROMPT_LOG}"
printf 'call\n' >> "${CALL_LOG}"
n=\$(wc -l < "${CALL_LOG}" | tr -d ' ')
case \$(( n % 4 )) in
	0) s=0.70 ;;
	1) s=0.80 ;;
	2) s=0.85 ;;
	*) s=0.90 ;;
esac
printf '{"score":%s,"passed":true,"confidence":0.9,"feedback":"stub"}' "\$s"
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

_calls() {
	[ -f "$CALL_LOG" ] || { echo 0; return; }
	wc -l < "$CALL_LOG" | tr -d ' '
}

@test "dry run shows the plan and spends nothing" {
	run "$HARNESS" --dry-run --samples 10 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"20"* ]] || return 1
	[ "$(_calls)" -eq 0 ]
}

@test "it calls the judge once per sample per file" {
	run "$HARNESS" --samples 4 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	[ "$(_calls)" -eq 8 ]
}

@test "it sends the same prompt the hook sends" {
	# The measurement only transfers to echo if the judge sees byte-identical
	# input. Both sides go through echo_build_judge_prompt; this pins that the
	# harness actually uses it rather than a lookalike that drifted.
	run "$HARNESS" --samples 4 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -eq 0 ] || return 1
	grep -q 'You are evaluating an agent prompt file for quality' "$PROMPT_LOG" || return 1
	grep -q 'Internal consistency: no contradictory instructions' "$PROMPT_LOG" || return 1
	grep -q -- '---END FILE---' "$PROMPT_LOG"
}

@test "it records the raw samples, not just the summary" {
	# Without the raw scores the statistics cannot be recomputed or challenged,
	# which is the failure mode of the 0.13-0.24 figure this replaces.
	run "$HARNESS" --samples 4 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -eq 0 ] || return 1
	[ -f "${OUT_DIR}/samples.json" ] || return 1
	jq -e '.samples | to_entries[0].value | length == 4' "${OUT_DIR}/samples.json" >/dev/null
}

@test "it records the model and prompt fingerprint the numbers belong to" {
	# A threshold is a property of one prompt scored by one model. Numbers that
	# do not say which are how 0.13-0.24 became unusable.
	run "$HARNESS" --samples 4 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.model | length > 0' "${OUT_DIR}/samples.json" >/dev/null || return 1
	jq -e '.prompt_sha256 | length == 64' "${OUT_DIR}/samples.json" >/dev/null
}

@test "it writes statistics with the three arms" {
	run "$HARNESS" --samples 10 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -eq 0 ] || return 1
	[ -f "${OUT_DIR}/stats.json" ] || return 1
	jq -e '.overall.single.p95 != null' "${OUT_DIR}/stats.json" >/dev/null || return 1
	jq -e '.overall.median3.p95 != null' "${OUT_DIR}/stats.json" >/dev/null || return 1
	jq -e '.overall.median5.p95 != null' "${OUT_DIR}/stats.json" >/dev/null
}

@test "a judge that returns nothing usable is skipped, not fatal" {
	# A single bad response must not throw away the other 29 calls.
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'not json at all'
STUB
	chmod +x "${STUB_BIN}/claude"
	run "$HARNESS" --samples 4 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"no usable"* ]]
}

@test "it refuses a file it cannot read rather than reporting on nothing" {
	run "$HARNESS" --samples 4 --out "$OUT_DIR" "${SUBJECT_DIR}/missing.md"
	[ "$status" -ne 0 ]
}

@test "it collects N usable samples even when the judge flakes" {
	# The first real run lost 4 of 30 calls, which dropped every file below the
	# 10 samples two disjoint 5-subsets need and silently emptied the median-5
	# arm entirely. Under-delivering on N has to be retried, not absorbed.
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf 'call\n' >> "${CALL_LOG}"
n=\$(wc -l < "${CALL_LOG}" | tr -d ' ')
if [ \$(( n % 3 )) -eq 0 ]; then
	printf 'garbage'
else
	printf '{"score":0.80,"passed":true,"confidence":0.9,"feedback":"stub"}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"

	run "$HARNESS" --samples 6 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.samples | to_entries[0].value | length == 6' "${OUT_DIR}/samples.json" >/dev/null || return 1
	# It retried rather than giving up at 6 attempts.
	[ "$(_calls)" -gt 6 ]
}

@test "it gives up retrying rather than spending without bound" {
	# A judge that never returns anything usable must not loop forever burning
	# calls. Bounded at 2x the request.
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat >/dev/null
printf 'call\n' >> "${CALL_LOG}"
printf 'garbage'
STUB
	chmod +x "${STUB_BIN}/claude"

	run "$HARNESS" --samples 5 --out "$OUT_DIR" "${SUBJECT_DIR}/one.md"
	[ "$status" -ne 0 ] || return 1
	[ "$(_calls)" -le 10 ]
}

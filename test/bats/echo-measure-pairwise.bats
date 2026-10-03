#!/usr/bin/env bats

# The harness behind ONL-103.
#
# The 72 real judge calls are manual. Nothing here spends a token: the stub
# stands in for the judge so the plumbing can be tested exhaustively. A test
# suite that costs 72 Haiku calls is a trap nobody runs -- the same reasoning
# that keeps the measure-* scripts themselves out of npm test, while this file
# runs in it for free.

setup() {
	# shellcheck source=../helpers/setup.bash
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/echo"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	HARNESS="${PLUGIN_ROOT}/scripts/measure-pairwise-discrimination.sh"

	SUBJECT_DIR="${BATS_TEST_TMPDIR}/subjects"
	mkdir -p "$SUBJECT_DIR"
	printf '# Reviewer\n\nA well-specified agent.\n' > "${SUBJECT_DIR}/one.md"
	printf '# Auditor\n\nAnother one.\n' > "${SUBJECT_DIR}/two.md"
	printf '# Scribe\n\nA third.\n' > "${SUBJECT_DIR}/three.md"

	OUT_DIR="${BATS_TEST_TMPDIR}/out"
	CALL_LOG="${BATS_TEST_TMPDIR}/calls"
	PROMPT_LOG="${BATS_TEST_TMPDIR}/prompts"

	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	# Answers from the prompt itself so both orders stay consistent: B better
	# when B's body sorts later, "same" when the bodies match. That makes the
	# stubbed run antisymmetric by construction, which is what the plumbing
	# assertions need -- the real judge's behavior is the open question.
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
printf '%s' "$prompt" >> "${PROMPT_LOG}"
printf 'call\n' >> "${CALL_LOG}"
a=$(printf '%s' "$prompt" | sed -n '/---DOCUMENT A:/,/---END DOCUMENT A---/p' | sed '1d;$d')
b=$(printf '%s' "$prompt" | sed -n '/---DOCUMENT B:/,/---END DOCUMENT B---/p' | sed '1d;$d')
if [[ "$a" == "$b" ]]; then
	printf '{"verdict":"same","confidence":0.9,"reason":"identical"}'
elif [[ "$b" > "$a" ]]; then
	printf '{"verdict":"better","confidence":0.8,"reason":"b"}'
else
	printf '{"verdict":"worse","confidence":0.8,"reason":"a"}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
	export PROMPT_LOG CALL_LOG
}

@test "dry-run reports the call count and spends nothing" {
	run "$HARNESS" --dry-run --repeats 2 \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md" "${SUBJECT_DIR}/three.md"
	[ "$status" -eq 0 ] || return 1
	# 3 self x 2 repeats + 3 pairs x 2 orders x 2 repeats = 6 + 12 = 18
	[[ "$output" == *"18"* ]] || return 1
	[ ! -f "$CALL_LOG" ]
}

@test "a real run spends exactly the calls it predicted" {
	run "$HARNESS" --repeats 2 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md" "${SUBJECT_DIR}/three.md"
	[ "$status" -eq 0 ] || return 1
	[ "$(wc -l < "$CALL_LOG" | tr -d ' ')" -eq 18 ]
}

@test "the self arm compares a document against its own content" {
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.self | length == 2' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.self[0].verdicts == ["same"]' "${OUT_DIR}/verdicts.json" >/dev/null
}

@test "every cross pair is evaluated in both orders" {
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.cross | length == 1' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.cross[0].ab | length == 1' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.cross[0].ba | length == 1' "${OUT_DIR}/verdicts.json" >/dev/null || return 1

	# The length checks above pass even if "both orders" were a lie: a call
	# that sends (A, B) twice instead of (A, B) then (B, A) still lands one
	# entry in each array. Pin the actual roles sent in each call instead of
	# inferring them from counts. Each call's A and B headers always come from
	# the same echo_build_pairwise_prompt invocation, so pairing the nearest
	# A header to the B header that follows it reconstructs exactly which
	# document sat in which slot for that call.
	pairs=$(awk '
		/^---DOCUMENT A: /{ sub(/^---DOCUMENT A: /, ""); sub(/---$/, ""); a = $0 }
		/^---DOCUMENT B: /{ sub(/^---DOCUMENT B: /, ""); sub(/---$/, ""); print a "|" $0 }
	' "$PROMPT_LOG")
	printf '%s\n' "$pairs" | grep -qF "${SUBJECT_DIR}/one.md|${SUBJECT_DIR}/two.md" || return 1
	printf '%s\n' "$pairs" | grep -qF "${SUBJECT_DIR}/two.md|${SUBJECT_DIR}/one.md"
}

@test "the run stamps the model and the prompt fingerprint" {
	# `model | length > 0` alone cannot fail while echo_config_model()'s own
	# hardcoded fallback happens to match the real shipped default -- the exact
	# ecosystem-449.36/.35 shape, where a broken config mirror (e.g. CLAUDE_
	# PLUGIN_ROOT not actually reaching the accessor at call time) keeps
	# "working" by accident, and nothing reports that the run measured the
	# DEFAULT model rather than echo's pinned judge. Pin the configured model
	# to a sentinel no real default could ever equal, so only an
	# actually-correct config read produces it.
	mkdir -p "$CLAUDE_HOME"
	cat > "${CLAUDE_HOME}/settings.json" <<'JSON'
{
	"echo": {
		"evaluation": {
			"model": "sentinel-model-for-task3-test"
		}
	}
}
JSON

	run "$HARNESS" --repeats 1 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.prompt_sha256 | length == 64' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.model == "sentinel-model-for-task3-test"' "${OUT_DIR}/verdicts.json" >/dev/null
}

@test "it writes a stats report carrying the kill verdict" {
	run "$HARNESS" --repeats 2 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	jq -e '.kill.verdict == "proceed" or .kill.verdict == "stop"' "${OUT_DIR}/stats.json" >/dev/null || return 1
	jq -e 'has("self_tie_rate") and has("true_discrimination")' "${OUT_DIR}/stats.json" >/dev/null
}

# The self arm is the cheapest possible kill: 6 of the 72 calls at R=1. Running
# it first means a judge that cannot recognize identical content costs almost
# nothing to rule out.
@test "the self arm runs before the cross arm" {
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1
	first_a=$(sed -n '/---DOCUMENT A:/{s/---DOCUMENT A: //;s/---//;p;q;}' "$PROMPT_LOG")
	first_b=$(grep -m1 -- '---DOCUMENT B:' "$PROMPT_LOG" | sed 's/---DOCUMENT B: //;s/---//')
	[ "$first_a" = "$first_b" ]
}

@test "an unreadable file is rejected before any judge call" {
	# Two files, not one: with a single nonexistent file the <2-files arity
	# guard answers first and the readability loop is never reached, so this
	# test would pass even if the readability check were deleted entirely.
	run "$HARNESS" --repeats 1 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/nope.md"
	[ "$status" -ne 0 ] || return 1
	[ ! -f "$CALL_LOG" ]
}

@test "fewer than two files cannot form a cross pair and is rejected" {
	# This is the ruling, not a default worth relaxing: a self-only run would
	# still populate stats.json (cross_antisymmetry: 0, true_discrimination: 0,
	# kill.verdict: "stop"), which reads as "pairwise comparison does not
	# discriminate" when the truth is "no pairs were supplied to discriminate
	# between." That is missing data presented as a measured failure -- the
	# same defect Task 2 spent two fix rounds removing from the arithmetic.
	# Rejecting here keeps the CLI from reintroducing it one layer up.
	run "$HARNESS" --dry-run --repeats 1 "${SUBJECT_DIR}/one.md"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"two"* ]] || [[ "$output" == *"2"* ]]
}

# ONL-103 task 2's review: self_comparisons_usable can never diverge from
# self_comparisons in pairwise-stats.mjs, because nothing recorded how many
# self comparisons were ATTEMPTED -- so a silently degraded self arm was
# invisible, even though self_tie_rate is the cheapest-kill gate. The fix
# lives here, where the calls are actually issued: verdicts.json carries a
# top-level `attempted` object counting every call made, parseable or not,
# separately from the usable verdicts in self[].verdicts / cross[].ab/.ba.
#
# Calls 2 and 6 are made to fail to parse so the test exercises a real split
# between attempted and usable, rather than one that would pass by accident
# whether or not the attempted count was tracked at all.
@test "attempted counts include calls whose response did not parse" {
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
prompt=$(cat)
printf '%s' "$prompt" >> "${PROMPT_LOG}"
printf 'call\n' >> "${CALL_LOG}"
n=$(wc -l < "${CALL_LOG}" | tr -d ' ')
case "$n" in
	2|6)
		printf 'not json at all'
		;;
	*)
		a=$(printf '%s' "$prompt" | sed -n '/---DOCUMENT A:/,/---END DOCUMENT A---/p' | sed '1d;$d')
		b=$(printf '%s' "$prompt" | sed -n '/---DOCUMENT B:/,/---END DOCUMENT B---/p' | sed '1d;$d')
		if [[ "$a" == "$b" ]]; then
			printf '{"verdict":"same","confidence":0.9,"reason":"identical"}'
		elif [[ "$b" > "$a" ]]; then
			printf '{"verdict":"better","confidence":0.8,"reason":"b"}'
		else
			printf '{"verdict":"worse","confidence":0.8,"reason":"a"}'
		fi
		;;
esac
STUB
	chmod +x "${STUB_BIN}/claude"

	run "$HARNESS" --repeats 2 --out "$OUT_DIR" \
		"${SUBJECT_DIR}/one.md" "${SUBJECT_DIR}/two.md"
	[ "$status" -eq 0 ] || return 1

	# 2 files x 2 repeats = 4 self calls; 1 pair x 2 orders x 2 repeats = 4
	# cross calls -- attempted must equal these predicted totals even though
	# calls 2 and 6 failed to parse.
	jq -e '.attempted.self_calls == 4' "${OUT_DIR}/verdicts.json" >/dev/null || return 1
	jq -e '.attempted.cross_calls == 4' "${OUT_DIR}/verdicts.json" >/dev/null || return 1

	# Usable verdicts must be strictly fewer than attempted calls in both arms
	# -- otherwise this test would pass whether or not failures were tracked.
	usable_self=$(jq '[.self[].verdicts[]] | length' "${OUT_DIR}/verdicts.json")
	usable_cross=$(jq '[.cross[].ab[], .cross[].ba[]] | length' "${OUT_DIR}/verdicts.json")
	[ "$usable_self" -lt 4 ] || return 1
	[ "$usable_cross" -lt 4 ]
}

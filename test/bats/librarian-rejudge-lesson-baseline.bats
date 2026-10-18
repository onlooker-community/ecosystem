#!/usr/bin/env bats
#
# Plumbing for rejudge-lesson-baseline.sh (1z07vm.6): re-score a recorded
# measurement's candidates with the judge prompt as it is now, holding the
# candidates fixed so the judge prompt is the only variable.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	REJUDGE="${PLUGIN_ROOT}/scripts/rejudge-lesson-baseline.sh"
	OUT="${BATS_TEST_TMPDIR}/out"
	BASELINE="${BATS_TEST_TMPDIR}/baseline.json"
	_seed_baseline
}

# One declined row (the transform produced nothing) and one judged row whose
# recorded verdicts are deliberately stale, so a re-judge is visible.
_seed_baseline() {
	jq -n '{
		rubric: {id: "lesson-promotion-public"},
		judge_model: "claude-haiku-4-5-20251001",
		transform_model: "claude-haiku-4-5-20251001",
		sample_mode: "spread", corpus_size: 2,
		candidates: [
			{artifact_id: "A-DECLINED", transform_outcome: "declined:no_resolution",
			 parked: 0, detail_length: 20, lesson_id: "", judged_scope_kind: "",
			 candidate: null, verdicts: [], aggregate: null, gate: null},
			{artifact_id: "A-JUDGED", transform_outcome: "proposed:L1:unscoped",
			 parked: 1, detail_length: 900, lesson_id: "L1",
			 judged_scope_kind: "version_independent",
			 candidate: {claim: "CLAIM-MARKER", rationale: "r",
			   evidence: {resolution: "Pin vitest to 3.x."},
			   applies_to: {stack: ["vite"], scope: {kind: "version_independent"},
			     file_patterns: [], task_kinds: []}},
			 verdicts: [{judge_type: "standard", feedback_summary: "STALE"},
			            {judge_type: "adversarial", feedback_summary: "STALE"}],
			 aggregate: null, gate: null}
		]}' > "$BASELINE"
}

# Records every prompt it is sent, one file per call.
_stub_claude() {
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	PROMPTS="${BATS_TEST_TMPDIR}/prompts"
	mkdir -p "$STUB_BIN" "$PROMPTS"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
cat > "\$(mktemp "${PROMPTS}/p.XXXXXX")"
printf '%s' '{"score":0.9,"passed":true,"judge_type":"standard","feedback_summary":"fresh","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.97}}'
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

@test "rejudge requires a baseline and an output directory" {
	run "$REJUDGE"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"usage:"* ]]
}

@test "a judged row gets fresh verdicts and a declined row passes through unchanged" {
	_stub_claude
	run "$REJUDGE" "$BASELINE" "$OUT"
	[ "$status" -eq 0 ] || return 1

	# Exactly two judge calls: the declined row costs nothing.
	[ "$(find "$PROMPTS" -type f | wc -l | tr -d ' ')" -eq 2 ] || return 1

	jq -e '.candidates[1].verdicts | length == 2 and all(.feedback_summary == "fresh")' \
		"${OUT}/samples.json" >/dev/null || return 1
	jq -e '.candidates[1].gate.passed == true' "${OUT}/samples.json" >/dev/null || return 1
	[ "$(jq -c '.candidates[0]' "${OUT}/samples.json")" = "$(jq -c '.candidates[0]' "$BASELINE")" ] || return 1
	[ -f "${OUT}/stats.json" ]
}

@test "rejudge scores with today's criterion definitions, not the baseline's" {
	_stub_claude
	run "$REJUDGE" "$BASELINE" "$OUT"
	[ "$status" -eq 0 ] || return 1

	local d prompt
	d=$(jq -r '.librarian.lesson_judging.rubrics[]
		| select(.id == "lesson-promotion-public")
		| .criteria[] | select(.name == "disclosure") | .description' \
		"${PLUGIN_ROOT}/config.json")
	prompt=$(cat "$(find "$PROMPTS" -type f | head -1)")
	[[ "$prompt" == *"CLAIM-MARKER"* ]] || return 1
	[[ "$prompt" == *"$d"* ]] || return 1
	# The recorded rubric is today's, descriptions included.
	jq -e '.rubric.criteria | length == 4 and all(.description | length > 0)' \
		"${OUT}/samples.json" >/dev/null
}

@test "rejudge fingerprints the judge prompt the same way the harness does" {
	# Otherwise a re-judge and a fresh measurement under one prompt would look
	# like two different instruments.
	_stub_claude
	run "$REJUDGE" "$BASELINE" "$OUT"
	[ "$status" -eq 0 ] || return 1

	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-rubric.sh"
	librarian_config_load "$REPO_ROOT"
	local expected
	expected=$(cat "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-auto.sh" \
		"${PLUGIN_ROOT}/scripts/lib/librarian-lesson-rubric.sh" \
		<(librarian_lesson_rubric_render_criteria "$(librarian_lesson_rubric_get lesson-promotion-public)") \
		| shasum -a 256 | cut -d' ' -f1)
	[ "$(jq -r '.judge_prompt_sha256' "${OUT}/samples.json")" = "$expected" ]
}

@test "rejudge writes nothing to the lesson store" {
	_stub_claude
	run "$REJUDGE" "$BASELINE" "$OUT"
	[ "$status" -eq 0 ] || return 1
	[ ! -e "${ONLOOKER_DIR}/librarian" ]
}

@test "rejudge refuses to write a measurement when every judge returned nothing" {
	# How this script's first version failed: a missing lib made every verdict
	# parse as empty, and the run "succeeded" with stats that read as 0%.
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "${STUB_BIN}/claude"
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	run "$REJUDGE" "$BASELINE" "$OUT"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"every judge panel returned nothing"* ]] || return 1
	[ ! -e "${OUT}/samples.json" ]
}

@test "a judge reply that is not a verdict is a judge failure, not a block" {
	# Observed live: the prose-tolerant extractor pulled a nested
	# {"kind":"version_independent"} out of an adversarial reply. Scored as a
	# verdict it counted as a block; production's librarian_lesson_judge
	# leaves such a panel unjudged, so the measurement must too.
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
if [[ "$*" == *"--agent tribunal-judge-adversarial"* ]]; then
	printf '%s' '{"kind":"version_independent"}'
else
	printf '%s' '{"score":0.9,"passed":true,"judge_type":"standard","feedback_summary":"fresh","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.97}}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	# The only judged row fails, which is "every panel empty".
	run "$REJUDGE" "$BASELINE" "$OUT"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"every judge panel returned nothing"* ]]
}

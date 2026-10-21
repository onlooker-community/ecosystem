#!/usr/bin/env bats
#
# Plumbing for the lesson-transform batch harness (ONL-110 / 1z07vm.1).
#
# The arithmetic lives in test/node/lesson-transform-stats.test.mjs. What is
# covered here is everything that can go wrong around it: argument validation,
# corpus selection, and the one property the harness exists to guarantee —
# that measuring never writes a terminal record into the real store.

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env
	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	HARNESS="${PLUGIN_ROOT}/scripts/measure-lesson-transform.sh"

	# evidence.artifact_ids is validated against ^[0-9A-HJKMNP-TV-Z]{26}$, so a
	# fixture id has to be a real ULID or every candidate declines
	# schema_invalid and the batch measures nothing. Generated with the
	# plugin's own helper rather than a hand-written constant.
	# shellcheck disable=SC1091
	source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"

	PROJECT_KEY="aaaaaaaaaaaa"
	CORPUS="${BATS_TEST_TMPDIR}/corpus"
	OUT="${BATS_TEST_TMPDIR}/out"
	mkdir -p "$CORPUS" "$OUT"
}

# Seed one archivist-shaped artifact. `detail` length drives sample ranking, so
# it is a parameter: a spread sample must be able to tell two artifacts apart.
# The FILE is named for readability; the artifact id inside it is a ULID.
# Usage: _seed_artifact <name> <detail_repeat_count>
_seed_artifact() {
	local name="$1" reps="${2:-10}" detail="" id
	id=$(librarian_ulid)
	local i
	for ((i = 0; i < reps; i++)); do
		detail="${detail}vitest 4.1.9 broke on vite 5.4.21 because the API was removed. "
	done
	jq -n --arg id "$id" --arg detail "$detail" \
		--arg created_at "$(relative_iso_days_ago 2)" \
		'{id: $id, kind: "decision", summary: "a decision",
		  detail: $detail, files: ["a.ts"], project_key: "aaaaaaaaaaaa",
		  session_id: "s1", source: "test", trigger: "t",
		  created_at: $created_at, updated_at: $created_at}' \
		> "${CORPUS}/${name}.json"
}

# An artifact carrying NO version token, so librarian_lesson_pregate routes the
# transform to `unscoped` mode and the candidate comes back parked.
# Usage: _seed_artifact_unversioned <name>
_seed_artifact_unversioned() {
	local name="$1" id
	id=$(librarian_ulid)
	jq -n --arg id "$id" --arg created_at "$(relative_iso_days_ago 2)" \
		'{id: $id, kind: "decision", summary: "a decision with no versions",
		  detail: "The test gate depended on a detached process, so it passed vacuously. Assert the side effect in the log instead of the call.",
		  files: ["a.ts"], project_key: "aaaaaaaaaaaa",
		  session_id: "s1", source: "test", trigger: "t",
		  created_at: $created_at, updated_at: $created_at}' \
		> "${CORPUS}/${name}.json"
}

# A `claude` whose transform answers with a PARKED candidate, whose
# justification call answers with <justification>, and whose judges return a
# verdict. The justification call is told apart by its prompt, not its flags:
# like the transform, it is a plain `claude -p` with no --agent.
#
# Usage: _stub_parked_claude [justification]
_stub_parked_claude() {
	local justification="${1:-The claim is about test design, not any tool version.}"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
args="\$*"
prompt=\$(cat)
if [[ "\$args" == *"--agent"* ]]; then
	printf '%s' '{"score":0.6,"passed":false,"judge_type":"standard","feedback_summary":"f","criterion_scores":{"grounding":0.6,"scope_accuracy":0.6,"generality":0.6,"disclosure":0.5}}'
elif [[ "\$prompt" == *"whether a lesson holds regardless of version"* ]]; then
	printf '%s' '${justification}'
else
	printf '%s' '{"claim":"c","rationale":"r","evidence":{"resolution":"Assert the side effect in the log."},"applies_to":{"stack":["bats"],"scope":{"kind":"unscoped"},"file_patterns":[],"task_kinds":[]}}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

# A `claude` that answers the transform with a valid candidate and each judge
# with a verdict. Branches on --agent, which is what separates a judge
# dispatch from a transform call.
#
# Usage: _stub_claude <adversarial_disclosure_score>
_stub_claude() {
	local adv_disclosure="${1:-0.95}"
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<STUB
#!/usr/bin/env bash
args="\$*"
cat > /dev/null
if [[ "\$args" == *"--agent tribunal-judge-adversarial"* ]]; then
	printf '%s' '{"score":0.62,"passed":false,"judge_type":"standard","feedback_summary":"overstated","criterion_scores":{"grounding":0.8,"scope_accuracy":0.8,"generality":0.8,"disclosure":${adv_disclosure}}}'
elif [[ "\$args" == *"--agent tribunal-judge-standard"* ]]; then
	printf '%s' '{"score":0.9,"passed":true,"judge_type":"standard","feedback_summary":"fine","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.95}}'
else
	printf '%s' '{"claim":"c","rationale":"r","evidence":{"resolution":"Pin vitest to 3.x."},"applies_to":{"stack":["vite"],"scope":{"kind":"versioned","versions":{"vite":"<6"}},"file_patterns":[],"task_kinds":[]}}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

@test "dry run reports the call budget without calling the model" {
	_seed_artifact A1
	_seed_artifact A2
	# A tripwire rather than an emptied PATH: stripping PATH also removes jq
	# and node, so the run would fail for a reason that proves nothing.
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	printf '#!/usr/bin/env bash\ntouch "%s/CALLED"\n' "$BATS_TEST_TMPDIR" \
		> "${STUB_BIN}/claude"
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	run "$HARNESS" --dry-run --samples 2 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS"
	[ "$status" -eq 0 ] || return 1
	! [ -e "${BATS_TEST_TMPDIR}/CALLED" ] || return 1
	[[ "$output" == *"2 transform calls + 4 judge calls (6 total)"* ]] || return 1
	[[ "$output" == *"lesson-promotion-public"* ]]
}

@test "the rubric and its floors are read from config, not hardcoded" {
	_seed_artifact A1
	run "$HARNESS" --dry-run --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS"
	[ "$status" -eq 0 ] || return 1
	# threshold 0.75 and gate majority both come out of config.json.
	[[ "$output" == *"threshold 0.75"* ]] || return 1
	[[ "$output" == *"gate majority"* ]]
}

@test "an unknown rubric id fails instead of measuring nothing" {
	_seed_artifact A1
	run "$HARNESS" --dry-run --rubric no-such-rubric \
		--project-key "$PROJECT_KEY" --artifacts-from "$CORPUS"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"not defined in config"* ]]
}

@test "a non-numeric sample count fails loudly rather than exiting 0 silently" {
	_seed_artifact A1
	run "$HARNESS" --samples notanumber --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS"
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"must be a positive integer"* ]]
}

@test "zero samples is rejected, not reported as an empty measurement" {
	_seed_artifact A1
	run "$HARNESS" --samples 0 --project-key "$PROJECT_KEY" --artifacts-from "$CORPUS"
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"must be a positive integer"* ]]
}

@test "a corpus of the wrong shape fails rather than scoring empty prompts" {
	# librarian's own artifacts/ carry title/body, not summary/detail. Feeding
	# those in would build prompts with no content and score them like a
	# result, which is the quietest way for this harness to lie.
	jq -n '{title: "t", body: "b", type: "decision"}' > "${CORPUS}/wrong.json"
	run "$HARNESS" --dry-run --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS"
	[ "$status" -ne 0 ] || return 1
	[[ "$output" == *"no usable artifacts"* ]]
}

@test "a full run writes samples and stats for every candidate" {
	_stub_claude
	_seed_artifact A1 5
	_seed_artifact A2 10
	_seed_artifact A3 15

	run "$HARNESS" --samples 3 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1
	[ -f "${OUT}/samples.json" ] || return 1
	[ -f "${OUT}/stats.json" ] || return 1

	jq -e '.candidates | length == 3' "${OUT}/samples.json" >/dev/null || return 1
	jq -e '.n == 3' "${OUT}/stats.json" >/dev/null || return 1
	jq -e '.transform.proposed == 3' "${OUT}/stats.json" >/dev/null
}

@test "measuring writes no terminal record into the real store" {
	# The property the sandbox exists for. A decline is permanent, so a harness
	# that declined in place would burn its own corpus on the first run and
	# have nothing to measure on the second.
	_stub_claude
	_seed_artifact A1 5
	_seed_artifact A2 10
	before=$(cat "${CORPUS}"/*.json | shasum -a 256)

	run "$HARNESS" --samples 2 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	! [ -e "${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons/declined.jsonl" ] || return 1
	! [ -d "${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons/proposals" ] || return 1
	! [ -d "${ONLOOKER_DIR}/librarian/${PROJECT_KEY}/lessons/approved" ] || return 1
	# The corpus itself must also come back untouched.
	[ "$(cat "${CORPUS}"/*.json | shasum -a 256)" = "$before" ]
}

@test "judge_type is stamped from the dispatched agent, not the model's claim" {
	# Both stubbed judges self-report "standard". If the harness trusted that,
	# the adversarial column — the entire point of ONL-110 — would be empty
	# and the panel would look unanimous.
	_stub_claude
	_seed_artifact A1 5

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	jq -e '[.candidates[0].verdicts[].judge_type] | sort == ["adversarial","standard"]' \
		"${OUT}/samples.json" >/dev/null || return 1
	jq -e '.judges.adversarial.n == 1 and .judges.standard.n == 1' \
		"${OUT}/stats.json" >/dev/null
}

@test "the per-criterion floor reports the adversary's low disclosure score" {
	# standard scores disclosure 0.95, adversarial 0.40, floor is 0.9. The
	# minimum rule must fail it; a mean (0.675) would also fail here, so the
	# adversarial score is pushed low enough that only a mean-based bug could
	# pass it... and high enough that `min` and `mean` disagree on grounding.
	_stub_claude 0.40
	_seed_artifact A1 5

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	jq -e '.criteria.disclosure.floor_fail == 1' "${OUT}/stats.json" >/dev/null || return 1
	jq -e '.criteria.disclosure.min_pass == 0.9' "${OUT}/stats.json" >/dev/null || return 1
	jq -e '.gate.passed == 0' "${OUT}/stats.json" >/dev/null
}

@test "both prompt shas and both models are stamped on the samples" {
	# A pass rate is a property of one transform prompt scored by one judge
	# prompt under one model pair. ONL-110's notes exist because an earlier
	# figure could not say which.
	_stub_claude
	_seed_artifact A1 5

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	jq -e '(.transform_sha256 | length) == 64' "${OUT}/samples.json" >/dev/null || return 1
	jq -e '(.judge_prompt_sha256 | length) == 64' "${OUT}/samples.json" >/dev/null || return 1
	jq -e '.transform_model != "" and .judge_model != ""' "${OUT}/samples.json" >/dev/null || return 1
	jq -e '.sample_mode == "spread" and .corpus_size == 1' "${OUT}/samples.json" >/dev/null
}

@test "the judge prompt fingerprint covers the criteria the judges were given" {
	# The prompt's criterion definitions live in config, not in
	# librarian-lesson-auto.sh. A fingerprint of that file alone would call two
	# runs the same instrument after a definition changed (1z07vm.6).
	_stub_claude
	_seed_artifact A1 5

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "${OUT}/public" --rubric lesson-promotion-public
	[ "$status" -eq 0 ] || return 1
	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "${OUT}/org" --rubric lesson-promotion
	[ "$status" -eq 0 ] || return 1

	a=$(jq -r '.judge_prompt_sha256' "${OUT}/public/samples.json")
	b=$(jq -r '.judge_prompt_sha256' "${OUT}/org/samples.json")
	[ "${#a}" -eq 64 ] || return 1
	[ "$a" != "$b" ]
}

@test "richest mode takes the longest artifacts and spread does not" {
	_seed_artifact SHORT 2
	_seed_artifact MEDIUM 20
	_seed_artifact LONG 60

	run "$HARNESS" --dry-run --samples 2 --sample-mode richest \
		--project-key "$PROJECT_KEY" --artifacts-from "$CORPUS"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"LONG.json"* ]] || return 1
	[[ "$output" == *"MEDIUM.json"* ]] || return 1
	[[ "$output" != *"SHORT.json"* ]] || return 1

	# spread spans the ranking, so it must reach the shortest artifact.
	run "$HARNESS" --dry-run --samples 2 --sample-mode spread \
		--project-key "$PROJECT_KEY" --artifacts-from "$CORPUS"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"LONG.json"* ]] || return 1
	[[ "$output" == *"SHORT.json"* ]]
}

@test "an unknown sample mode is rejected" {
	_seed_artifact A1
	run "$HARNESS" --sample-mode sideways --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS"
	[ "$status" -eq 1 ] || return 1
	[[ "$output" == *"must be spread or richest"* ]]
}

@test "a judge that returns nothing is recorded as unjudged, not as a failure" {
	# Empty is infrastructure, not a verdict. Folding it into the pass rate
	# would let a flaky judge read as a transform regression.
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
args="$*"
cat > /dev/null
if [[ "$args" == *"--agent"* ]]; then
	printf ''
else
	printf '%s' '{"claim":"c","rationale":"r","evidence":{"resolution":"Pin vitest to 3.x."},"applies_to":{"stack":["vite"],"scope":{"kind":"versioned","versions":{"vite":"<6"}},"file_patterns":[],"task_kinds":[]}}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
	_seed_artifact A1 5

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	# Transformed fine, but no panel: n excludes it and the gate rate is n/a.
	jq -e '.transform.proposed == 1' "${OUT}/stats.json" >/dev/null || return 1
	jq -e '.n == 0' "${OUT}/stats.json" >/dev/null || return 1
	jq -e '.gate.pass_rate == null' "${OUT}/stats.json" >/dev/null
}

@test "a parked candidate is judged in the shape production confirms it into" {
	# librarian_lesson_auto_confirm_one rewrites a parked candidate's scope to
	# {"kind":"version_independent"} BEFORE auto_judge_one sees it, and the
	# judge prompt asserts "a MODEL asserted that this lesson holds regardless
	# of version". Judging the raw {"kind":"unscoped"} candidate asserts a claim
	# the candidate does not make. Measured on three real candidates: that
	# mismatch cost scope_accuracy ~0.11 and grounding ~0.05, in the same
	# direction every time.
	_stub_parked_claude
	_seed_artifact_unversioned A1

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	jq -e '.candidates[0].parked == true' "${OUT}/samples.json" >/dev/null || return 1
	jq -e '.candidates[0].judged_scope_kind == "version_independent"' \
		"${OUT}/samples.json" >/dev/null || return 1
	jq -e '.confirm_shape == true' "${OUT}/samples.json" >/dev/null
}

@test "a parked candidate reaches the judges carrying the model's justification" {
	# Production confirms through librarian_lesson_confirm, which writes
	# {kind: "version_independent", justification: <sentence>}. Judging the
	# bare {kind: "version_independent"} shows the panel an assertion with its
	# reason stripped, and every scope_accuracy floor in the 2026-10-19 control
	# arm (9 of 9) cited exactly that missing support.
	_stub_parked_claude "Assertions on the log hold whatever the tool versions are."
	_seed_artifact_unversioned A1

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	jq -e '.candidates[0].confirm_outcome | startswith("confirmed:")' \
		"${OUT}/samples.json" >/dev/null || return 1
	jq -e '.candidates[0].candidate.applies_to.scope.justification
		== "Assertions on the log hold whatever the tool versions are."' \
		"${OUT}/samples.json" >/dev/null || return 1
	jq -e '.candidates[0].verdicts | length == 2' "${OUT}/samples.json" >/dev/null
}

@test "a refused justification is left unjudged, as production leaves it pending" {
	# auto_confirm_one returns skipped:no_justification on REFUSE and the
	# candidate never reaches a jury, so judging it here would measure a
	# panel production never convenes.
	_stub_parked_claude "REFUSE"
	_seed_artifact_unversioned A1

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	jq -e '.candidates[0].confirm_outcome == "skipped:no_justification"' \
		"${OUT}/samples.json" >/dev/null || return 1
	jq -e '.candidates[0].verdicts == []' "${OUT}/samples.json" >/dev/null || return 1
	jq -e '.n == 0' "${OUT}/stats.json" >/dev/null
}

@test "a refused candidate's record carries the model's reason" {
	# The false-refusal measurement hand-labels refusals as right or wrong,
	# which needs the reason beside the claim it refused (ONL-183).
	_stub_parked_claude "REFUSE: The stack names only internal plugins."
	_seed_artifact_unversioned A1

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	jq -e '.candidates[0].refusal_reason == "The stack names only internal plugins."' \
		"${OUT}/samples.json" >/dev/null
}

@test "a candidate nobody refused records a null refusal reason" {
	_stub_parked_claude
	_seed_artifact_unversioned A1

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	jq -e '.candidates[0] | has("refusal_reason") and .refusal_reason == null' \
		"${OUT}/samples.json" >/dev/null
}

@test "--raw-scope reproduces the pre-fix shape for comparison" {
	_stub_parked_claude
	_seed_artifact_unversioned A1

	run "$HARNESS" --samples 1 --raw-scope --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1
	jq -e '.confirm_shape == false' "${OUT}/samples.json" >/dev/null || return 1
	# The pre-fix shape: the raw parked scope reaches the judge unchanged.
	jq -e '.candidates[0].judged_scope_kind == "unscoped"' "${OUT}/samples.json" >/dev/null
}

@test "a versioned candidate's scope is left alone" {
	# Only a PARKED claim gets rewritten. A bound range is what the transform
	# asserted and must reach the judge unchanged.
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
args="$*"
cat > /dev/null
if [[ "$args" == *"--agent"* ]]; then
	printf '%s' '{"score":0.9,"passed":true,"judge_type":"standard","feedback_summary":"f","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.95}}'
else
	printf '%s' '{"claim":"c","rationale":"r","evidence":{"resolution":"Pin vitest to 3.x."},"applies_to":{"stack":["vite"],"scope":{"kind":"versioned","versions":{"vite":"<6"}},"file_patterns":[],"task_kinds":[]}}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
	_seed_artifact A1 5

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1
	jq -e '.candidates[0].judged_scope_kind == "versioned"' "${OUT}/samples.json" >/dev/null
}

@test "the stamped corpus path carries no absolute home path" {
	# These artifacts get committed. `corpus` is provenance, not a filesystem
	# handle, so the home and ONLOOKER_DIR prefixes are collapsed to literals —
	# otherwise every committed measurement leaks the operator's username and
	# only resolves on one machine.
	_stub_claude
	# The corpus must sit UNDER $HOME or this test asserts nothing: bats' own
	# tmpdir is outside it, so the unfixed harness would pass vacuously.
	CORPUS="${HOME}/corpus-under-home"
	mkdir -p "$CORPUS"
	_seed_artifact A1 5

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1

	corpus=$(jq -r '.corpus' "${OUT}/samples.json")
	[[ "$corpus" != /Users/* ]] || return 1
	[[ "$corpus" != /home/* ]] || return 1
	[[ "$corpus" != "$HOME"* ]] || return 1
	! grep -qF "$HOME" "${OUT}/samples.json" || return 1
	! grep -qF "$HOME" "${OUT}/stats.json"
}

@test "a corpus under ONLOOKER_DIR is stamped with the variable, not the path" {
	_stub_claude
	UNDER="${ONLOOKER_DIR}/archivist/${PROJECT_KEY}"
	mkdir -p "$UNDER"
	CORPUS="$UNDER"
	_seed_artifact A1 5

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$UNDER" --out "$OUT"
	[ "$status" -eq 0 ] || return 1
	jq -e '.corpus | startswith("$ONLOOKER_DIR/")' "${OUT}/samples.json" >/dev/null
}

@test "a judge reply that is not a verdict is recorded as a judge failure" {
	# Observed live in the 1z07vm.6 re-judge: an adversarial reply yielded a
	# nested {"kind":"version_independent"}. Production leaves such a panel
	# unjudged; the harness used to score it as a block.
	_seed_artifact A1 5
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
args="$*"
cat > /dev/null
if [[ "$args" == *"--agent tribunal-judge-adversarial"* ]]; then
	printf '%s' '{"kind":"version_independent"}'
elif [[ "$args" == *"--agent tribunal-judge-standard"* ]]; then
	printf '%s' '{"score":0.9,"passed":true,"judge_type":"standard","feedback_summary":"fine","criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.95}}'
else
	printf '%s' '{"claim":"c","rationale":"r","evidence":{"resolution":"Pin vitest to 3.x."},"applies_to":{"stack":["vite"],"scope":{"kind":"versioned","versions":{"vite":"<6"}},"file_patterns":[],"task_kinds":[]}}'
fi
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"

	run "$HARNESS" --samples 1 --project-key "$PROJECT_KEY" \
		--artifacts-from "$CORPUS" --out "$OUT"
	[ "$status" -eq 0 ] || return 1
	jq -e '.candidates[0].candidate != null and .candidates[0].verdicts == [] and .candidates[0].gate == null' \
		"${OUT}/samples.json" >/dev/null
}

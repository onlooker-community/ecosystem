#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	PLUGIN_ROOT="${REPO_ROOT}/plugins/librarian"
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	export ONLOOKER_ECOSYSTEM_ROOT="$REPO_ROOT"

	PROJECT_REPO="${BATS_TEST_TMPDIR}/repo"
	mkdir -p "$PROJECT_REPO"
	git -C "$PROJECT_REPO" init -q
	git -C "$PROJECT_REPO" config user.email t@example.com
	git -C "$PROJECT_REPO" config user.name "Test"
	git -C "$PROJECT_REPO" remote add origin git@github.com:org/fixture.git

	source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-rubric.sh"
	librarian_config_load "$PROJECT_REPO"

	PROJECT_KEY=$(librarian_project_key "$PROJECT_REPO")

	source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-judge.sh"
	# librarian_cli_lessons_list (exercised by the CLI tests below) calls
	# librarian_lesson_list_by_status, which lives here — not pulled in by
	# any of the sources above.
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-review.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-cli.sh"

	# A claude stub that fails loudly. Any path asserted to spend no tokens
	# must not invoke it. Same technique that proved stage 5's unavailable
	# path and stage 6's no-model guarantee.
	STUB_BIN="${BATS_TEST_TMPDIR}/bin"
	mkdir -p "$STUB_BIN"
	cat > "${STUB_BIN}/claude" <<'STUB'
#!/usr/bin/env bash
echo "claude was invoked but this path must spend no tokens" >&2
exit 99
STUB
	chmod +x "${STUB_BIN}/claude"
	export PATH="${STUB_BIN}:${PATH}"
}

@test "org visibility selects the lesson-promotion rubric" {
	run librarian_lesson_rubric_id_for_visibility "org"
	[ "$status" -eq 0 ]
	[ "$output" = "lesson-promotion" ]
}

@test "public visibility selects the public rubric" {
	run librarian_lesson_rubric_id_for_visibility "public"
	[ "$status" -eq 0 ]
	[ "$output" = "lesson-promotion-public" ]
}

@test "private visibility selects no rubric" {
	run librarian_lesson_rubric_id_for_visibility "private"
	[ "$status" -eq 0 ]
	[ "$output" = "" ]
}

@test "an unknown visibility is refused" {
	run librarian_lesson_rubric_id_for_visibility "everyone"
	[ "$status" -ne 0 ]
}

@test "the org rubric gates on majority and the public rubric on unanimous" {
	local org public
	org=$(librarian_lesson_rubric_get "lesson-promotion")
	public=$(librarian_lesson_rubric_get "lesson-promotion-public")
	[ "$(printf '%s' "$org" | jq -r '.gate_policy')" = "majority" ]
	[ "$(printf '%s' "$public" | jq -r '.gate_policy')" = "unanimous" ]
}

@test "both rubrics carry a 0.75 score threshold and two judge types" {
	local r
	for r in lesson-promotion lesson-promotion-public; do
		local got
		got=$(librarian_lesson_rubric_get "$r")
		[ "$(printf '%s' "$got" | jq -r '.score_threshold')" = "0.75" ]
		[ "$(printf '%s' "$got" | jq -c '.judge_types')" = '["standard","adversarial"]' ]
	done
}

@test "neither rubric carries a max_iterations knob" {
	# There is no Actor in this pipeline, so a retry setting would be a knob
	# that cannot do anything. See the spec's "There is no Actor" section.
	local r
	for r in lesson-promotion lesson-promotion-public; do
		local got
		got=$(librarian_lesson_rubric_get "$r")
		[ "$(printf '%s' "$got" | jq 'has("max_iterations")')" = "false" ]
	done
}

@test "each rubric's criterion weights sum to exactly 1.00" {
	# Tribunal validates each weight in [0,1] but never their total. An
	# unnormalized set would silently mis-score the moment ecosystem-pht
	# implements real weighted_mean.
	local r
	for r in lesson-promotion lesson-promotion-public; do
		local sum
		sum=$(librarian_lesson_rubric_get "$r" | jq '[.criteria[].weight] | add | . * 100 | round')
		[ "$sum" -eq 100 ]
	done
}

@test "only the public rubric carries the disclosure criterion" {
	local org public
	org=$(librarian_lesson_rubric_get "lesson-promotion" | jq -c '[.criteria[].name]')
	public=$(librarian_lesson_rubric_get "lesson-promotion-public" | jq -c '[.criteria[].name]')
	[ "$org" = '["grounding","scope_accuracy","generality"]' ]
	[ "$public" = '["grounding","scope_accuracy","generality","disclosure"]' ]
}

@test "disclosure carries the highest floor of any criterion" {
	local r floor others_max
	r=$(librarian_lesson_rubric_get "lesson-promotion-public")
	floor=$(printf '%s' "$r" | jq '.criteria[] | select(.name == "disclosure") | .min_pass')
	others_max=$(printf '%s' "$r" | jq '[.criteria[] | select(.name != "disclosure") | .min_pass] | max')
	[ "$floor" = "0.9" ] || return 1
	[ "$(jq -n --argjson a "$floor" --argjson b "$others_max" '$a > $b')" = "true" ] || return 1
}

@test "an unknown rubric id is refused and echoes nothing" {
	run librarian_lesson_rubric_get "no-such-rubric"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
}

_seed_confirmed() {
	local id="$1" visibility="$2"
	local dir="$(librarian_lessons_dir "$PROJECT_KEY")/proposals"
	mkdir -p "$dir"
	jq -n --arg id "$id" --arg v "$visibility" \
		--arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{ id: $id, artifact_id: "art-\($id)", status: "confirmed",
		   visibility: $v, confirmed_at: $t,
		   candidate: { claim: "Prefer jq -c for compact output",
		                rationale: "Readable diffs",
		                evidence: { resolution: "Applied and verified" },
		                applies_to: { stack: ["bash"],
		                              scope: { kind: "versioned", versions: ">=3.2" } } } }' \
		> "${dir}/${id}.json"
}

_status_of() {
	jq -r '.status' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/${1}.json"
}

# Two judges, both passing, mean 0.85 — clears the 0.75 threshold.
_verdicts_pass() {
	printf '%s' '[{"judge_type":"standard","score":0.9,"passed":true,"confidence":0.9,"feedback_summary":"Well grounded."},{"judge_type":"adversarial","score":0.8,"passed":true,"confidence":0.8,"feedback_summary":"Holds up."}]'
}

# Split panel: mean 0.85 still clears the threshold, but one judge blocks.
_verdicts_split() {
	printf '%s' '[{"judge_type":"standard","score":0.95,"passed":true,"confidence":0.9,"feedback_summary":"Strong."},{"judge_type":"adversarial","score":0.75,"passed":false,"confidence":0.8,"feedback_summary":"Scope claim is not supported."}]'
}

@test "aggregate averages the judges' scores" {
	run librarian_lesson_aggregate "$(_verdicts_pass)"
	[ "$status" -eq 0 ]
	# 0.9 + 0.8 = 1.7 / 2 = 0.85
	[ "$(printf '%s' "$output" | awk '{printf "%.2f", $1}')" = "0.85" ]
}

@test "aggregate refuses an empty panel" {
	run librarian_lesson_aggregate '[]'
	[ "$status" -ne 0 ]
}

@test "a unanimous gate blocks when one judge blocks" {
	run librarian_lesson_gate "unanimous" "$(_verdicts_split)" "0.85" "0.75"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$output" | jq -r '.reason')" = "jury_not_unanimous" ]
}

@test "majority and unanimous diverge on a two-of-three panel" {
	# Two judges with one dissenter does NOT clear majority either — it needs
	# strictly more than half. A three-judge panel is the smallest one where
	# the two policies actually disagree, which is what this pins.
	local three='[{"judge_type":"standard","score":0.95,"passed":true},{"judge_type":"adversarial","score":0.9,"passed":true},{"judge_type":"standard","score":0.75,"passed":false}]'
	run librarian_lesson_gate "majority" "$three" "0.867" "0.75"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.passed')" = "true" ]

	run librarian_lesson_gate "unanimous" "$three" "0.867" "0.75"
	[ "$(printf '%s' "$output" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$output" | jq -r '.reason')" = "jury_not_unanimous" ]
}

@test "a below-threshold aggregate blocks even when every judge passed" {
	local low='[{"judge_type":"standard","score":0.6,"passed":true},{"judge_type":"adversarial","score":0.6,"passed":true}]'
	run librarian_lesson_gate "majority" "$low" "0.6" "0.75"
	[ "$(printf '%s' "$output" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$output" | jq -r '.reason')" = "below_threshold" ]
}

@test "a private candidate is approved with no model call and no judges" {
	_seed_confirmed "priv01" "private"
	run librarian_lesson_judge "$PROJECT_KEY" "priv01" '[]'
	[ "$status" -eq 0 ]
	[ "$(_status_of priv01)" = "approved" ]

	local v
	v=$(jq -c '.verdict' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/priv01.json")
	[ "$(printf '%s' "$v" | jq -r '.reason')" = "private_no_jury" ]
	[ "$(printf '%s' "$v" | jq -c '.judges')" = "[]" ]
	[ "$(printf '%s' "$v" | jq -r '.rubric_id')" = "null" ]
}

@test "an org candidate the jury passes is approved under the org rubric" {
	_seed_confirmed "org01" "org"
	run librarian_lesson_judge "$PROJECT_KEY" "org01" "$(_verdicts_pass)"
	[ "$status" -eq 0 ]
	[ "$(_status_of org01)" = "approved" ]

	local v
	v=$(jq -c '.verdict' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/org01.json")
	[ "$(printf '%s' "$v" | jq -r '.rubric_id')" = "lesson-promotion" ]
	[ "$(printf '%s' "$v" | jq -r '.gate_policy')" = "majority" ]
	[ "$(printf '%s' "$v" | jq '.judges | length')" -eq 2 ]
}

@test "a public candidate one judge blocks is rejected though the aggregate clears" {
	# The whole reason public differs from org. The mean here is 0.85, well
	# above the 0.75 threshold; only the unanimous policy stops it.
	_seed_confirmed "pub01" "public"
	run librarian_lesson_judge "$PROJECT_KEY" "pub01" "$(_verdicts_split)"
	[ "$status" -eq 0 ]
	[ "$(_status_of pub01)" = "rejected" ]

	local v
	v=$(jq -c '.verdict' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/pub01.json")
	[ "$(printf '%s' "$v" | jq -r '.rubric_id')" = "lesson-promotion-public" ]
	[ "$(printf '%s' "$v" | jq -r '.gate_policy')" = "unanimous" ]
	[ "$(printf '%s' "$v" | jq -r '.reason')" = "jury_not_unanimous" ]
}

@test "the same split panel is rejected at org, but for the majority reason" {
	# The verdicts are identical to the public case above. 1 of 2 passing
	# clears neither policy, so both tiers reject — what this pins is that the
	# RUBRIC actually differs by visibility, via the recorded reason and id.
	# Without this, the public test alone would pass even if both visibilities
	# resolved to the same rubric.
	_seed_confirmed "org02" "org"
	run librarian_lesson_judge "$PROJECT_KEY" "org02" "$(_verdicts_split)"
	[ "$status" -eq 0 ]
	[ "$(_status_of org02)" = "rejected" ]

	local v
	v=$(jq -c '.verdict' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/org02.json")
	[ "$(printf '%s' "$v" | jq -r '.rubric_id')" = "lesson-promotion" ]
	[ "$(printf '%s' "$v" | jq -r '.gate_policy')" = "majority" ]
	[ "$(printf '%s' "$v" | jq -r '.reason')" = "jury_not_majority" ]
}

@test "a three-element panel (one extra judge) is unjudged, not judged with an extra vote" {
	# Both builtin rubrics declare exactly two judge_types (standard,
	# adversarial). A three-element panel can no longer produce a real
	# outcome divergence between majority and unanimous through
	# librarian_lesson_judge: the composition check requires the panel's
	# judge_type multiset to equal the rubric's, so an extra judge is
	# rejected before the gate ever runs. (For a real two-judge panel,
	# majority and unanimous are the same decision anyway: majority needs
	# strictly more than half, which for count=2 means both pass — exactly
	# what unanimous requires.) The gate-level divergence between the two
	# policies on a hypothetical three-judge panel is still pinned directly
	# by "majority and unanimous diverge on a two-of-three panel" above.
	local three='[{"judge_type":"standard","score":0.95,"passed":true},{"judge_type":"adversarial","score":0.9,"passed":true},{"judge_type":"standard","score":0.8,"passed":false}]'

	_seed_confirmed "tier01" "org"
	local before_org
	before_org=$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/tier01.json")
	run librarian_lesson_judge "$PROJECT_KEY" "tier01" "$three"
	[ "$status" -eq 2 ]
	[ "$(_status_of tier01)" = "confirmed" ]
	[ "$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/tier01.json")" = "$before_org" ]

	_seed_confirmed "tier02" "public"
	local before_public
	before_public=$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/tier02.json")
	run librarian_lesson_judge "$PROJECT_KEY" "tier02" "$three"
	[ "$status" -eq 2 ]
	[ "$(_status_of tier02)" = "confirmed" ]
	[ "$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/tier02.json")" = "$before_public" ]
}

@test "a one-judge panel on a public candidate is unjudged, not approved by a lone judge" {
	# The sharpest case: a single approving judge is trivially unanimous, so
	# without the composition check this would promote a public lesson on
	# one vote — the exact failure the unanimous policy exists to prevent.
	_seed_confirmed "solo01" "public"
	local before
	before=$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/solo01.json")

	run librarian_lesson_judge "$PROJECT_KEY" "solo01" \
		'[{"judge_type":"standard","score":0.9,"passed":true}]'
	[ "$status" -eq 2 ]
	[ "$(_status_of solo01)" = "confirmed" ]
	[ "$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/solo01.json")" = "$before" ]
}

@test "a one-judge panel on an org candidate is unjudged" {
	_seed_confirmed "solo02" "org"
	local before
	before=$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/solo02.json")

	run librarian_lesson_judge "$PROJECT_KEY" "solo02" \
		'[{"judge_type":"standard","score":0.9,"passed":true}]'
	[ "$status" -eq 2 ]
	[ "$(_status_of solo02)" = "confirmed" ]
	[ "$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/solo02.json")" = "$before" ]
}

@test "two judges of the same type is unjudged, not a stand-in for the missing type" {
	# Two "standard" verdicts and no "adversarial" one is individually
	# well-typed and even sized right, so only a composition check catches
	# it.
	_seed_confirmed "dup01" "org"
	local before
	before=$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/dup01.json")

	run librarian_lesson_judge "$PROJECT_KEY" "dup01" \
		'[{"judge_type":"standard","score":0.9,"passed":true},{"judge_type":"standard","score":0.8,"passed":true}]'
	[ "$status" -eq 2 ]
	[ "$(_status_of dup01)" = "confirmed" ]
	[ "$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/dup01.json")" = "$before" ]
}

@test "a rejected proposal keeps its file, correctly marked rejected with a recorded verdict" {
	# librarian_lesson_seen scans proposals/ by artifact_id; deleting the file
	# would let the same artifact re-propose and re-pay tokens next scan.
	# _seed_confirmed already creates this file before the call, so asserting
	# only -f here would pass even if the function body did nothing at all —
	# the assertion must pin what a *rejected* proposal looks like, not
	# merely that the file was not deleted.
	_seed_confirmed "rej01" "public"
	run librarian_lesson_judge "$PROJECT_KEY" "rej01" "$(_verdicts_split)"
	[ "$status" -eq 0 ]
	[ -f "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/rej01.json" ]
	[ "$(_status_of rej01)" = "rejected" ]

	local v
	v=$(jq -c '.verdict' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/rej01.json")
	[ "$(printf '%s' "$v" | jq -r '.passed')" = "false" ]
	[ "$(printf '%s' "$v" | jq '.judges | length')" -eq 2 ]
}

@test "a malformed verdict leaves the candidate confirmed and writes nothing" {
	_seed_confirmed "bad01" "org"
	local before
	before=$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/bad01.json")

	run librarian_lesson_judge "$PROJECT_KEY" "bad01" '[{"judge_type":"standard","score":"not-a-number","passed":true}]'
	[ "$status" -eq 2 ]
	[ "$(_status_of bad01)" = "confirmed" ]
	[ "$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/bad01.json")" = "$before" ]
}

@test "unparseable verdict JSON is unjudged, not rejected" {
	_seed_confirmed "bad02" "org"
	run librarian_lesson_judge "$PROJECT_KEY" "bad02" 'this is not json'
	[ "$status" -eq 2 ]
	[ "$(_status_of bad02)" = "confirmed" ]
}

@test "an empty panel on a non-private candidate is unjudged" {
	_seed_confirmed "bad03" "public"
	run librarian_lesson_judge "$PROJECT_KEY" "bad03" '[]'
	[ "$status" -eq 2 ]
	[ "$(_status_of bad03)" = "confirmed" ]
}

# The three malformed-panel tests above are all double-covered downstream:
# a non-numeric score fails jq arithmetic inside librarian_lesson_aggregate,
# unparseable JSON fails its `jq 'length'`, and an empty array is refused by
# librarian_lesson_aggregate's own zero-length check. Every one of those
# still returns 2 even with the `usable` guard deleted, so none of them
# actually pins the guard itself. A wrong-typed or absent `passed` field is
# the one shape that reaches neither check: the scores parse fine, so the
# aggregate succeeds, and jq's `select(.passed == true)` on a non-boolean or
# missing `passed` just quietly evaluates false instead of erroring. Without
# the guard, that panel gets judged as though every judge blocked — written
# `rejected` rather than left `confirmed` for a retry, which is exactly the
# "malformed panel permanently buries a good lesson" failure this stage
# exists to prevent.
@test "a wrong-typed passed field is unjudged, not silently scored as a block" {
	_seed_confirmed "bad04" "org"
	local before
	before=$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/bad04.json")

	run librarian_lesson_judge "$PROJECT_KEY" "bad04" \
		'[{"judge_type":"standard","score":0.9,"passed":"true"},{"judge_type":"adversarial","score":0.85,"passed":"true"}]'
	[ "$status" -eq 2 ]
	[ "$(_status_of bad04)" = "confirmed" ]
	[ "$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/bad04.json")" = "$before" ]
}

@test "a missing passed field is unjudged, not silently scored as a block" {
	_seed_confirmed "bad05" "org"
	local before
	before=$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/bad05.json")

	run librarian_lesson_judge "$PROJECT_KEY" "bad05" \
		'[{"judge_type":"standard","score":0.9},{"judge_type":"adversarial","score":0.85}]'
	[ "$status" -eq 2 ]
	[ "$(_status_of bad05)" = "confirmed" ]
	[ "$(cat "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/bad05.json")" = "$before" ]
}

@test "judging proceeds only from confirmed" {
	_seed_confirmed "st01" "org"
	local path="$(librarian_lessons_dir "$PROJECT_KEY")/proposals/st01.json"
	local tmp="${BATS_TEST_TMPDIR}/st01.json"
	jq '.status = "pending"' "$path" > "$tmp" && mv "$tmp" "$path"

	run librarian_lesson_judge "$PROJECT_KEY" "st01" "$(_verdicts_pass)"
	[ "$status" -eq 1 ]
	[[ "$output" == *"pending"* ]] || return 1
	[ "$(_status_of st01)" = "pending" ]
}

@test "re-judging an already-approved candidate is refused, naming the status" {
	_seed_confirmed "st02" "org"
	run librarian_lesson_judge "$PROJECT_KEY" "st02" "$(_verdicts_pass)"
	[ "$status" -eq 0 ]

	run librarian_lesson_judge "$PROJECT_KEY" "st02" "$(_verdicts_pass)"
	[ "$status" -eq 1 ]
	[[ "$output" == *"approved"* ]] || return 1
}

@test "a missing lesson is refused" {
	run librarian_lesson_judge "$PROJECT_KEY" "nope01" "$(_verdicts_pass)"
	[ "$status" -eq 1 ]
	[[ "$output" == *"not found"* ]] || return 1
}

@test "lessons judge records a verdict through the CLI" {
	_seed_confirmed "cli01" "org"
	run librarian_cli lessons judge "cli01" "$(_verdicts_pass)" "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ "$(_status_of cli01)" = "approved" ]
	[[ "$output" == *"approved"* ]] || return 1
}

@test "lessons judge reports an unjudged candidate distinctly from a rejection" {
	_seed_confirmed "cli02" "org"
	run librarian_cli lessons judge "cli02" '[{"judge_type":"standard","score":"nope","passed":true}]' "$PROJECT_REPO"
	[ "$status" -eq 2 ]
	[[ "$output" == *"could not be judged"* ]] || return 1
	[ "$(_status_of cli02)" = "confirmed" ]
}

@test "lessons judge requires a lesson id" {
	run librarian_cli lessons judge
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage:"* && "$output" == *"judge"* ]] || return 1
}

@test "lessons judge requires verdicts" {
	run librarian_cli lessons judge "cli03"
	[ "$status" -ne 0 ]
	[[ "$output" == *"usage:"* && "$output" == *"judge"* ]] || return 1
}

@test "lessons judge rejects an unknown flag" {
	_seed_confirmed "cli04" "org"
	run librarian_cli lessons judge "cli04" "$(_verdicts_pass)" --force
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown option"* && "$output" == *"--force"* ]] || return 1
}

@test "lessons list --confirmed --json emits rows carrying visibility" {
	_seed_confirmed "js01" "public"
	_seed_confirmed "js02" "org"
	run librarian_cli lessons list --confirmed --json "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" -eq 2 ]
	[ "$(printf '%s' "$output" | jq -r '[.[] | select(.visibility == "public")] | length')" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.[0] | has("id")')" = "true" ]
}

@test "lessons list --json on an empty set emits an empty array, not prose" {
	# The skill parses this; a human-readable empty-state message would break it.
	run librarian_cli lessons list --confirmed --json "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ "$output" = "[]" ]
}

@test "bare lessons list is unchanged by the --json addition" {
	run librarian_cli lessons list "$PROJECT_REPO"
	[ "$status" -eq 0 ]
	[ "$output" = "No pending lessons." ]
}

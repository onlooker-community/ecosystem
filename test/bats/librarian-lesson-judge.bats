#!/usr/bin/env bats

# `run --separate-stderr` (used below) requires bats >= 1.5.0.
bats_require_minimum_version 1.5.0

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

@test "both the org and public rubrics gate on majority" {
	# unanimous was the public tier's stand-in protection and never worked at
	# this panel size — see ecosystem-j74. Both rubrics are majority now; what
	# still differs between them is the criteria, pinned separately below.
	local org public
	org=$(librarian_lesson_rubric_get "lesson-promotion")
	public=$(librarian_lesson_rubric_get "lesson-promotion-public")
	[ "$(printf '%s' "$org" | jq -r '.gate_policy')" = "majority" ]
	[ "$(printf '%s' "$public" | jq -r '.gate_policy')" = "majority" ]
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

# Two judges, both passing. Aggregate 0.85 at org / 0.88 at public — both clear
# the 0.75 threshold, and every criterion sits above its floor.
#
# criterion_scores are the superset of both rubrics' criteria, so the same
# fixture serves org (grounding / scope_accuracy / generality) and public (those
# plus disclosure). They are not decoration: librarian_lesson_judge refuses a
# panel that leaves a floored criterion unscored, so a fixture without them is
# UNJUDGED (2) rather than a verdict. disclosure is 0.95 on both judges because
# its floor is 0.9 and the floor is now the panel MINIMUM.
_verdicts_pass() {
	printf '%s' '[{"judge_type":"standard","score":0.9,"passed":true,"confidence":0.9,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.95},"feedback_summary":"Well grounded."},{"judge_type":"adversarial","score":0.8,"passed":true,"confidence":0.8,"criterion_scores":{"grounding":0.8,"scope_accuracy":0.8,"generality":0.8,"disclosure":0.95},"feedback_summary":"Holds up."}]'
}

# Split panel: the aggregate still clears the threshold and no floor is
# violated, so the jury policy is the only thing that blocks it.
_verdicts_split() {
	printf '%s' '[{"judge_type":"standard","score":0.95,"passed":true,"confidence":0.9,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.95,"disclosure":0.95},"feedback_summary":"Strong."},{"judge_type":"adversarial","score":0.75,"passed":false,"confidence":0.8,"criterion_scores":{"grounding":0.75,"scope_accuracy":0.75,"generality":0.75,"disclosure":0.95},"feedback_summary":"Scope claim is not supported."}]'
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
	# The mean here is 0.85, well above the 0.75 threshold; only the jury
	# policy stops it. A split 1-of-2 panel fails majority the same way it
	# failed unanimous at this panel size — see ecosystem-j74.
	_seed_confirmed "pub01" "public"
	run librarian_lesson_judge "$PROJECT_KEY" "pub01" "$(_verdicts_split)"
	[ "$status" -eq 0 ]
	[ "$(_status_of pub01)" = "rejected" ]

	local v
	v=$(jq -c '.verdict' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/pub01.json")
	[ "$(printf '%s' "$v" | jq -r '.rubric_id')" = "lesson-promotion-public" ]
	[ "$(printf '%s' "$v" | jq -r '.gate_policy')" = "majority" ]
	[ "$(printf '%s' "$v" | jq -r '.reason')" = "jury_not_majority" ]
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

@test "judge writes the verdict atomically, never truncating in place" {
	# Same discriminator as the three atomic-write tests in
	# librarian-lesson-review.bats: `printf > path` truncates before writing,
	# so an interrupted write leaves a zero-byte proposal that every verb
	# refuses and list_pending hides — unrecoverable even by unconfirm. A
	# read-only-dir test would NOT catch this: it blocks the open entirely,
	# so the truncating code also leaves the original intact. What
	# distinguishes atomic from not is that the write lands somewhere else
	# first, so spy on the rename.
	_seed_confirmed "atomic01" "org"

	local marker="${BATS_TEST_TMPDIR}/mv-called"
	rm -f "$marker"
	mv() { printf '%s -> %s\n' "$1" "$2" >> "$marker"; command mv "$@"; }

	run librarian_lesson_judge "$PROJECT_KEY" "atomic01" "$(_verdicts_pass)"
	[ "$status" -eq 0 ]

	[ -f "$marker" ]
	grep -q "proposals/atomic01.json" "$marker" || return 1
	[ "$(_status_of atomic01)" = "approved" ]
	unset -f mv
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

@test "a rubric missing from config is refused with a reason, not silently" {
	# Reachable by config drift: the visibility map still names a rubric that
	# librarian.lesson_judging.rubrics no longer defines. State stays safe —
	# nothing is written — but a user sees only an exit code.
	_seed_confirmed "cfg01" "org"
	_LIBRARIAN_CONFIG=$(printf '%s' "$_LIBRARIAN_CONFIG" | jq 'del(.librarian.lesson_judging.rubrics)')

	run --separate-stderr librarian_lesson_judge "$PROJECT_KEY" "cfg01" "$(_verdicts_pass)"
	[ "$status" -eq 1 ]
	[ "$output" = "" ]
	[[ "$stderr" == *"rubric"* ]] || return 1
	[ "$(_status_of cfg01)" = "confirmed" ]
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

PUBLIC_RUBRIC='{"id":"lesson-promotion-public","criteria":[
  {"name":"grounding","weight":0.32,"min_pass":0.7},
  {"name":"scope_accuracy","weight":0.24,"min_pass":0.7},
  {"name":"generality","weight":0.14,"min_pass":0.6},
  {"name":"disclosure","weight":0.30,"min_pass":0.9}],
  "score_threshold":0.75,"gate_policy":"majority"}'

@test "lesson aggregate weights criteria when scores are present" {
	local w m verdicts
	verdicts='[
	  {"judge_type":"standard","score":0.5,"passed":true,"criterion_scores":{"grounding":1.0,"scope_accuracy":1.0,"generality":1.0,"disclosure":0.0}},
	  {"judge_type":"adversarial","score":0.5,"passed":true,"criterion_scores":{"grounding":1.0,"scope_accuracy":1.0,"generality":1.0,"disclosure":0.0}}
	]'
	w=$(librarian_lesson_aggregate "$verdicts" "$PUBLIC_RUBRIC")
	m=$(librarian_lesson_aggregate "$verdicts")
	# weighted: 0.32+0.24+0.14 = 0.70 over a weight sum of 1.0. Plain mean: 0.5.
	awk -v a="$w" -v b="$m" 'BEGIN { exit !(a != b) }' || return 1
	awk -v a="$w" 'BEGIN { exit !(a > 0.699 && a < 0.701) }'
}

@test "lesson aggregate degrades to the plain mean without criterion scores" {
	local out
	out=$(librarian_lesson_aggregate \
		'[{"judge_type":"standard","score":0.8,"passed":true},
		  {"judge_type":"adversarial","score":0.6,"passed":true}]' "$PUBLIC_RUBRIC")
	awk -v a="$out" 'BEGIN { exit !(a > 0.699 && a < 0.701) }'
}

@test "lesson aggregate still returns 1 on an empty panel" {
	run librarian_lesson_aggregate '[]' "$PUBLIC_RUBRIC"
	[ "$status" -eq 1 ]
}

@test "lesson aggregate normalizes weights that do not sum to 1.0" {
	# librarian_lesson_rubric_get validates NOTHING, so a mis-summed rubric
	# reaches this function where tribunal's validator would have refused it.
	local out
	out=$(librarian_lesson_aggregate \
		'[{"judge_type":"standard","score":0.1,"passed":true,"criterion_scores":{"grounding":1.0,"disclosure":0.0}}]' \
		'{"criteria":[{"name":"grounding","weight":1.8,"min_pass":0.7},{"name":"disclosure","weight":0.2,"min_pass":0.9}]}')
	awk -v a="$out" 'BEGIN { exit !(a > 0.899 && a < 0.901) }'
}

@test "a low disclosure score blocks a public lesson under majority" {
	# The reason this whole thread exists: disclosure's 0.9 floor blocks even
	# though both judges passed and the aggregate clears 0.75.
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.9,"disclosure":0.4}},
	  {"judge_type":"adversarial","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.9,"disclosure":0.4}}
	]' "0.78" "0.75" "$PUBLIC_RUBRIC")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "disclosure"' >/dev/null
}

@test "a generality score above its floor does not block a public lesson" {
	# Pins generality's 0.6 floor: 0.65 clears it. This is NOT a difference from
	# the old `unanimous` policy — both judges pass, so unanimous accepted it
	# too, and at a two-judge panel no fixture can tell the policies apart.
	# See ecosystem-j74.
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.65,"disclosure":0.95}},
	  {"judge_type":"adversarial","score":0.85,"passed":true,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.65,"disclosure":0.95}}
	]' "0.88" "0.75" "$PUBLIC_RUBRIC")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "lesson gate: a verdict with no criterion_scores key at all never blocks" {
	# Every verdict emitted before judges shipped criterion_scores. Note this
	# case is caught by the OUTER type guard and never reaches has() — it does
	# NOT pin the per-criterion absence guard. The next test does that.
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true},
	  {"judge_type":"adversarial","score":0.85,"passed":true}
	]' "0.88" "0.75" "$PUBLIC_RUBRIC")
	printf '%s' "$out" | jq -e '.passed == true and .reason == "gate_passed"' >/dev/null
}

@test "lesson gate: scores present but one floored criterion omitted does not block" {
	# THE test that pins the has() guard. These verdicts DO carry
	# criterion_scores, so they survive the outer type guard and reach the
	# per-criterion lookup — but `disclosure`, whose floor is 0.9, is absent.
	# Substituting `// 0` for has() makes disclosure read as 0.0 and blocks.
	#
	# Written as its own test because the case above cannot fail when has() is
	# deleted: its fixture is filtered one layer earlier. Two different absences
	# sharing one test is how an outer guard silently stands in for an inner one
	# — this project has hit that shape eight times.
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.9}},
	  {"judge_type":"adversarial","score":0.85,"passed":true,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.85}}
	]' "0.88" "0.75" "$PUBLIC_RUBRIC")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.reason == "gate_passed"' >/dev/null
}

@test "lesson gate: a criterion scored zero does block" {
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"disclosure":0.0}},
	  {"judge_type":"adversarial","score":0.85,"passed":true,"criterion_scores":{"disclosure":0.0}}
	]' "0.88" "0.75" "$PUBLIC_RUBRIC")
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "disclosure"' >/dev/null
}

@test "lesson gate: below_threshold still wins over criterion_floor" {
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.2,"passed":true,"criterion_scores":{"disclosure":0.1}},
	  {"judge_type":"adversarial","score":0.2,"passed":true,"criterion_scores":{"disclosure":0.1}}
	]' "0.20" "0.75" "$PUBLIC_RUBRIC")
	printf '%s' "$out" | jq -e '.reason == "below_threshold"' >/dev/null
}

@test "lesson gate: jury policy still wins over criterion_floor" {
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":false,"criterion_scores":{"disclosure":0.1}},
	  {"judge_type":"adversarial","score":0.9,"passed":false,"criterion_scores":{"disclosure":0.1}}
	]' "0.90" "0.75" "$PUBLIC_RUBRIC")
	printf '%s' "$out" | jq -e '.reason == "jury_not_majority"' >/dev/null
}

@test "lesson gate: works with no rubric at all" {
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true},
	  {"judge_type":"adversarial","score":0.85,"passed":true}
	]' "0.88" "0.75")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "lesson gate: a hyphenated criterion name gates correctly" {
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"scope-accuracy":0.1}},
	  {"judge_type":"adversarial","score":0.9,"passed":true,"criterion_scores":{"scope-accuracy":0.1}}
	]' "0.90" "0.75" '{"criteria":[{"name":"scope-accuracy","weight":1.0,"min_pass":0.7}]}')
	printf '%s' "$out" | jq -e '.failed_criterion == "scope-accuracy"' >/dev/null
}

@test "an end-to-end public judge is rejected by a criterion floor, not just the unit gate" {
	# Pins Step 5's threading, not just librarian_lesson_gate in isolation: both
	# judges pass unanimously and the mean (0.875) clears the 0.75 threshold, so
	# without the rubric reaching the gate through librarian_lesson_judge this
	# would approve. disclosure's 0.9 floor is what actually blocks it.
	_seed_confirmed "floor01" "public"
	local verdicts='[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.9,"disclosure":0.4}},
	  {"judge_type":"adversarial","score":0.85,"passed":true,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.85,"disclosure":0.4}}
	]'
	run librarian_lesson_judge "$PROJECT_KEY" "floor01" "$verdicts"
	[ "$status" -eq 0 ]
	[ "$(_status_of floor01)" = "rejected" ]

	local v
	v=$(jq -c '.verdict' "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/floor01.json")
	[ "$(printf '%s' "$v" | jq -r '.reason')" = "criterion_floor" ]
}

@test "the public rubric no longer relies on unanimous" {
	# unanimous was a stand-in for the disclosure floor and never worked: at the
	# configured panel of 2, unanimous and majority are the same function for
	# every possible pass count. ecosystem-j74.
	local policy
	policy=$(jq -r '.librarian.lesson_judging.rubrics[]
		| select(.id == "lesson-promotion-public") | .gate_policy' \
		"${REPO_ROOT}/plugins/librarian/config.json")
	[ "$policy" = "majority" ]
}

@test "the public rubric keeps disclosure's floor at 0.9" {
	# The floor is now the ONLY thing making public stricter than org. If this
	# drops, the public tier silently loses its protection entirely.
	local floor
	floor=$(jq -r '.librarian.lesson_judging.rubrics[]
		| select(.id == "lesson-promotion-public")
		| .criteria[] | select(.name == "disclosure") | .min_pass' \
		"${REPO_ROOT}/plugins/librarian/config.json")
	[ "$floor" = "0.9" ]
}

@test "org and public rubrics differ by more than their gate policy" {
	# Both are `majority` now. If the criteria ever converge too, the two tiers
	# become indistinguishable and the public tier is inert again — the exact
	# shape of j74.
	local org_crit pub_crit
	org_crit=$(jq -c '[.librarian.lesson_judging.rubrics[]
		| select(.id == "lesson-promotion") | .criteria[].name] | sort' \
		"${REPO_ROOT}/plugins/librarian/config.json")
	pub_crit=$(jq -c '[.librarian.lesson_judging.rubrics[]
		| select(.id == "lesson-promotion-public") | .criteria[].name] | sort' \
		"${REPO_ROOT}/plugins/librarian/config.json")
	[ "$org_crit" != "$pub_crit" ]
}

@test "the librarian walk names every public rubric criterion to its judges" {
	# A bare grep for "criterion_scores" passes even when the walk hands judges
	# the wrong key names — which silently disables the floor, since no key
	# matches the rubric. Assert the actual names, read from config.
	local skill name
	skill="${REPO_ROOT}/plugins/librarian/skills/librarian/SKILL.md"
	grep -q 'criterion_scores' "$skill" || return 1

	while IFS= read -r name; do
		grep -q "$name" "$skill" || return 1
	done < <(jq -r '.librarian.lesson_judging.rubrics[]
		| select(.id == "lesson-promotion-public") | .criteria[].name' \
		"${REPO_ROOT}/plugins/librarian/config.json")
}

@test "a floor rejection records which criterion failed" {
	# "reason": "criterion_floor" without the criterion name is no more
	# actionable than "blocked" — the whole argument for a distinct reason
	# was naming the thing that failed.
	_seed_confirmed "floorname01" "public"
	local verdicts='[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.9,"disclosure":0.4}},
	  {"judge_type":"adversarial","score":0.85,"passed":true,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.85,"disclosure":0.4}}
	]'
	run librarian_lesson_judge "$PROJECT_KEY" "floorname01" "$verdicts"
	[ "$status" -eq 0 ] || return 1
	[ "$(_status_of floorname01)" = "rejected" ] || return 1

	local path
	path="$(librarian_lessons_dir "$PROJECT_KEY")/proposals/floorname01.json"
	jq -e '.verdict.reason == "criterion_floor"' "$path" >/dev/null || return 1
	jq -e '.verdict.failed_criterion == "disclosure"' "$path" >/dev/null
}

@test "an approved verdict carries no failed_criterion key" {
	# Absent rather than null: a key that is always present but usually empty
	# invites `// ""` at the read site, which is how this pipeline has
	# repeatedly lost the absent-vs-empty distinction.
	_seed_confirmed "floorname02" "public"
	local verdicts='[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.9,"disclosure":0.95}},
	  {"judge_type":"adversarial","score":0.9,"passed":true,"criterion_scores":{"grounding":0.9,"scope_accuracy":0.9,"generality":0.9,"disclosure":0.95}}
	]'
	run librarian_lesson_judge "$PROJECT_KEY" "floorname02" "$verdicts"
	[ "$status" -eq 0 ] || return 1

	local path
	path="$(librarian_lessons_dir "$PROJECT_KEY")/proposals/floorname02.json"
	jq -e '.verdict | has("failed_criterion") | not' "$path" >/dev/null
}

@test "a floored criterion no judge scored is UNJUDGED, not approved" {
	# C2: librarian dispatches tribunal's judge agents, whose shipped example
	# keys are tribunal's rubric. A judge following that example emits keys
	# matching nothing here, disclosure never runs, and the lesson publishes.
	# Refusing is right: the candidate stays confirmed and is retried.
	_seed_confirmed "cov01" "public"
	local verdicts='[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"correctness":0.9,"completeness":0.9,"safety":0.2,"clarity":0.9}},
	  {"judge_type":"adversarial","score":0.9,"passed":true,"criterion_scores":{"correctness":0.9,"completeness":0.9,"safety":0.2,"clarity":0.9}}
	]'
	run --separate-stderr librarian_lesson_judge "$PROJECT_KEY" "cov01" "$verdicts"
	[ "$status" -eq 2 ] || return 1
	[ "$(_status_of cov01)" = "confirmed" ] || return 1
	local re='disclosure'
	[[ "$stderr" =~ $re ]]
}

@test "a panel that scored every floored criterion but too little weight is UNJUDGED" {
	# Isolates the coverage fraction from the unscored-floors check above.
	#
	# Both SHIPPED rubrics floor every one of their criteria, so with them a
	# floor-complete panel always covers 1.0 of the weight and this branch is
	# unreachable: a fixture built on the org rubric would be caught by the
	# unscored check and would still pass with the coverage guard deleted —
	# the outer-guard-stands-in-for-the-inner shape this repo keeps hitting.
	# ADR-004 lets a user override `rubrics`, so an unfloored criterion is a
	# real configuration, and it is the only one that reaches this guard.
	_LIBRARIAN_CONFIG=$(printf '%s' "$_LIBRARIAN_CONFIG" | jq '
		.librarian.lesson_judging.rubrics = [
		  { id: "lesson-promotion",
		    criteria: [ { name: "grounding", weight: 0.2, min_pass: 0.7 },
		                { name: "depth", weight: 0.8 } ],
		    score_threshold: 0.75,
		    judge_types: ["standard", "adversarial"],
		    gate_policy: "majority" } ]')

	_seed_confirmed "cov02" "org"
	# grounding is the only floored criterion and both judges scored it, so the
	# unscored check passes. Coverage is 0.2 of 1.0 — well under the 0.6 floor.
	local verdicts='[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.9}},
	  {"judge_type":"adversarial","score":0.9,"passed":true,"criterion_scores":{"grounding":0.9}}
	]'
	run --separate-stderr librarian_lesson_judge "$PROJECT_KEY" "cov02" "$verdicts"
	[ "$status" -eq 2 ] || return 1
	[ "$(_status_of cov02)" = "confirmed" ] || return 1
	local re='rubric weight'
	[[ "$stderr" =~ $re ]]
}

@test "a below_threshold block still names the criterion that failed its floor" {
	# The worst disclosure failures drag the aggregate under threshold, so
	# before this they landed as below_threshold with no failed_criterion —
	# the diagnostic absent exactly where it matters most.
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.95,"disclosure":0.0}},
	  {"judge_type":"adversarial","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.95,"disclosure":0.0}}
	]' "0.665" "0.75" "$PUBLIC_RUBRIC")
	printf '%s' "$out" | jq -e '.reason == "below_threshold"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "disclosure"' >/dev/null
}

@test "a lesson floor uses the lowest judge score, not the mean" {
	local out
	out=$(librarian_lesson_gate "majority" '[
	  {"judge_type":"standard","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.95,"disclosure":1.0}},
	  {"judge_type":"adversarial","score":0.9,"passed":true,"criterion_scores":{"grounding":0.95,"scope_accuracy":0.95,"generality":0.95,"disclosure":0.85}}
	]' "0.93" "0.75" "$PUBLIC_RUBRIC")
	# The discriminating pair: the mean of 1.0/0.85 is 0.925 and CLEARS the 0.9
	# floor, so a mean-based floor passes this panel. The min, 0.85, does not.
	# 0.99/0.8 would not discriminate — that mean is 0.895, already under 0.9.
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "disclosure"' >/dev/null
}

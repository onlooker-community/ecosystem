# Lesson Judging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give librarian a human-invoked jury that judges confirmed lesson candidates against a visibility-scoped rubric and records an `approved` or `rejected` verdict on each proposal.

**Architecture:** The agent orchestrates and bash decides. A new `/librarian lessons judge` route gathers confirmed candidates, dispatches tribunal's judge subagents per candidate, and hands the raw verdicts to bash, which selects the rubric by visibility, aggregates, gates, and writes the result. Everything except subagent dispatch lives in testable shell.

**Tech Stack:** bash (macOS bash 3.2 compatible), `jq`, bats, `awk` for float comparison.

## Deviation from the spec, and why

The spec says the skill "parses their verdicts, aggregates and gates" and gives the
lib only the write (`librarian_lesson_record_verdict <key> <lesson_id> <verdict_json>`).

**This plan moves aggregation and gating into bash instead**, and the lib entry
point becomes `librarian_lesson_judge <key> <lesson_id> <verdicts_json>`.

The reason is the spec's own Testing section. It requires asserting that "a public
candidate that one judge blocks is rejected even when the aggregate clears
`score_threshold`" — that is gate behavior. Gate logic living in SKILL.md prose
cannot be exercised by bats at all, so the spec's central test would be
unwritable. The division of labor the spec argues for (agent orchestrates, bash
does the rest) is preserved; the seam simply sits one step later.

## Global Constraints

- Runtime artifacts go under `$ONLOOKER_DIR`; never a hardcoded `~/.onlooker`.
- Project key via `librarian_project_key <repo-root>` from `librarian-project-key.sh`. Never recompute the SHA.
- **No event emission anywhere in this stage.** `@onlooker-community/schema` 2.11.0 registers only `meridian.lesson.curated`; the emitter exits 1 on an unknown `event_type`.
- **Do not source any file under `plugins/tribunal/`.** The ADR in Task 5 licenses reusing tribunal's *agent definitions* by name, not its bash. Librarian implements its own aggregate and gate.
- Bash 3.2 compatible: no associative arrays, no `${var^^}`, no `mapfile`.
- bats runs under macOS system bash 3.2, where a failing **non-final** `[[ ]]` does NOT fail the test. Every non-final `[[ ]]` assertion needs `|| return 1`. Single-bracket `[ ]` gates on its own.
- **Assert on messages, not just exit codes.** Two vacuous tests already shipped on the `si6` branch because a non-zero exit was produced by an unrelated guard. If a test asserts a refusal, pin the refusal's text.
- Every new bats assertion must be broken once to confirm it discriminates. Do fault injection in a **fresh `git worktree`**, never the shared working tree.
- American English in all comments, messages, and commits.
- Commit via the `/commit` skill contract: `<type>(<scope>): <subject> :emoji:`, subject ≤72 chars including the emoji, why-focused body.

## File Structure

| File | Responsibility |
|---|---|
| `plugins/librarian/config.json` | **Modify.** Add `librarian.lesson_judging.rubrics` — the two builtins. |
| `plugins/librarian/scripts/lib/librarian-lesson-rubric.sh` | **Create.** Load a rubric by id; map a visibility to its rubric id. |
| `plugins/librarian/scripts/lib/librarian-lesson-judge.sh` | **Create.** Aggregate verdicts, apply the gate, write the result. The heart of the stage. |
| `plugins/librarian/scripts/lib/librarian-cli.sh` | **Modify.** Add the `judge` verb and `list --confirmed --json`. |
| `plugins/librarian/skills/librarian/SKILL.md` | **Modify.** Add the `/librarian lessons judge` route. |
| `plugins/librarian/docs/adr/002-agent-definitions-are-shared-assets.md` | **Create.** Record the cross-plugin reading. |
| `test/bats/librarian-lesson-judge.bats` | **Create.** Rubric, aggregate, gate, and record tests. |
| `test/bats/librarian-lesson-review.bats` | **Modify.** Assert `unconfirm` refuses `approved` and `rejected`. |

---

### Task 1: The two rubrics and their loader

**Files:**
- Modify: `plugins/librarian/config.json`
- Create: `plugins/librarian/scripts/lib/librarian-lesson-rubric.sh`
- Test: `test/bats/librarian-lesson-judge.bats`

**Interfaces:**
- Consumes: `librarian_config_load <repo_root>` and `librarian_config_get <jq-path>` from `librarian-config.sh`.
- Produces:
  - `librarian_lesson_rubric_id_for_visibility <visibility>` → echoes `lesson-promotion` for `org`, `lesson-promotion-public` for `public`, empty string for `private`; returns 1 for anything else.
  - `librarian_lesson_rubric_get <rubric_id>` → echoes the rubric object as compact JSON; returns 1 and echoes nothing if unknown.

- [ ] **Step 1: Write the failing tests**

Create `test/bats/librarian-lesson-judge.bats`:

```bash
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
	local floor
	floor=$(librarian_lesson_rubric_get "lesson-promotion-public" \
		| jq '.criteria[] | select(.name == "disclosure") | .min_pass')
	[ "$floor" = "0.9" ]
}

@test "an unknown rubric id is refused and echoes nothing" {
	run librarian_lesson_rubric_get "no-such-rubric"
	[ "$status" -ne 0 ]
	[ "$output" = "" ]
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: every test FAILS — `librarian-lesson-rubric.sh` does not exist, so `source` in `setup()` errors.

- [ ] **Step 3: Add the rubrics to config.json**

Add a `lesson_judging` key inside the existing `librarian` object in
`plugins/librarian/config.json`, as a sibling of `lesson_transform`.

**Use these weights verbatim. Do not recompute them.** The public set is the org
set scaled to 70% with disclosure taking the remaining 30%, rounded *to preserve
the sum*: `0.35 × 0.7 = 0.245` is written `0.24`, because rounding it to `0.25`
totals 1.01.

```json
"lesson_judging": {
  "rubrics": [
    {
      "id": "lesson-promotion",
      "criteria": [
        { "name": "grounding", "weight": 0.45, "min_pass": 0.7 },
        { "name": "scope_accuracy", "weight": 0.35, "min_pass": 0.7 },
        { "name": "generality", "weight": 0.20, "min_pass": 0.6 }
      ],
      "score_threshold": 0.75,
      "judge_types": ["standard", "adversarial"],
      "gate_policy": "majority"
    },
    {
      "id": "lesson-promotion-public",
      "criteria": [
        { "name": "grounding", "weight": 0.32, "min_pass": 0.7 },
        { "name": "scope_accuracy", "weight": 0.24, "min_pass": 0.7 },
        { "name": "generality", "weight": 0.14, "min_pass": 0.6 },
        { "name": "disclosure", "weight": 0.30, "min_pass": 0.9 }
      ],
      "score_threshold": 0.75,
      "judge_types": ["standard", "adversarial"],
      "gate_policy": "unanimous"
    }
  ]
}
```

- [ ] **Step 4: Write the rubric loader**

Create `plugins/librarian/scripts/lib/librarian-lesson-rubric.sh`:

```bash
#!/usr/bin/env bash
# Rubric selection for lesson judging.
#
# Two builtins live in config.json under librarian.lesson_judging.rubrics,
# mirroring tribunal's rubric.builtins shape so they stay legible to anyone who
# knows tribunal. Librarian loads them itself rather than sourcing tribunal's
# lib — see docs/adr/002-agent-definitions-are-shared-assets.md.
#
# The per-criterion weights and min_pass floors are DECLARED BUT INERT today:
# tribunal_aggregate discards the rubric it is handed, and no per-criterion
# score reaches any gate. They are the honest statement of intent and go live
# unchanged when ecosystem-pht lands. Nothing here may depend on them.
#
# Exposes:
#   librarian_lesson_rubric_id_for_visibility <visibility>
#   librarian_lesson_rubric_get <rubric_id>

# Map a confirmed lesson's visibility to the rubric that judges it.
#
# `private` maps to the empty string on purpose: that tier runs no jury at all,
# which is what makes cost scale with intent rather than artifact volume.
#
# Usage: librarian_lesson_rubric_id_for_visibility <visibility>
librarian_lesson_rubric_id_for_visibility() {
	case "${1:-}" in
		private) printf '' ;;
		org)     printf 'lesson-promotion' ;;
		public)  printf 'lesson-promotion-public' ;;
		*)       return 1 ;;
	esac
	return 0
}

# Echo one rubric as compact JSON. Returns 1 and echoes nothing if unknown.
#
# Usage: librarian_lesson_rubric_get <rubric_id>
librarian_lesson_rubric_get() {
	local rubric_id="${1:-}"
	[[ -z "$rubric_id" ]] && return 1

	local rubrics found
	rubrics=$(librarian_config_get '.librarian.lesson_judging.rubrics')
	[[ -z "$rubrics" || "$rubrics" == "null" ]] && return 1

	found=$(printf '%s' "$rubrics" | jq -c --arg id "$rubric_id" \
		'map(select(.id == $id)) | first // empty' 2>/dev/null) || return 1
	[[ -z "$found" || "$found" == "null" ]] && return 1

	printf '%s' "$found"
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: PASS, 11/11.

If `librarian_config_get` returns the rubrics array as a string rather than
JSON, check how `config_get` in `scripts/lib/config-loader.sh` handles array
values and adjust the `jq` invocation — do not work around it by re-reading
`config.json` directly, which would skip the settings overlay layers.

- [ ] **Step 6: Prove the weight-sum test discriminates**

In a throwaway worktree only:

```bash
git worktree add /tmp/lj-verify HEAD
# In /tmp/lj-verify, change the public rubric's scope_accuracy weight 0.24 -> 0.25
bats test/bats/librarian-lesson-judge.bats
# Expected: "each rubric's criterion weights sum to exactly 1.00" FAILS
git worktree remove --force /tmp/lj-verify
```

- [ ] **Step 7: Run lint and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-rubric.sh
git add plugins/librarian/config.json \
        plugins/librarian/scripts/lib/librarian-lesson-rubric.sh \
        test/bats/librarian-lesson-judge.bats
```

Commit subject: `feat(librarian): add the two lesson-promotion rubrics :scales:`

---

### Task 2: Aggregate, gate, and record the verdict

**Files:**
- Create: `plugins/librarian/scripts/lib/librarian-lesson-judge.sh`
- Test: `test/bats/librarian-lesson-judge.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_rubric_id_for_visibility`, `librarian_lesson_rubric_get` (Task 1); `librarian_lessons_dir <key>` from `librarian-lesson-storage.sh`.
- Produces:
  - `librarian_lesson_aggregate <verdicts_json>` → echoes the mean of `.score`, or empty and returns 1 on an empty array.
  - `librarian_lesson_gate <gate_policy> <verdicts_json> <aggregate> <score_threshold>` → echoes `{"passed":bool,"reason":string}`.
  - `librarian_lesson_judge <key> <lesson_id> <verdicts_json>` → returns **0** when a verdict was recorded, **1** on a usage/state error, **2** when the candidate is unjudged and nothing was written.

**The three return codes are the interface Task 3 and Task 4 depend on.** `2` is
not a failure — it means "could not judge," which the spec requires be kept
distinct from "judged and failed."

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-judge.bats`. Add these to `setup()` after
the existing `source` lines:

```bash
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
	source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-judge.sh"

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
```

And this helper, which seeds a confirmed proposal:

```bash
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
```

Now the tests:

```bash
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

@test "a three-judge panel with one dissenter separates the two tiers" {
	# The case where the tiers genuinely produce different OUTCOMES, not just
	# different reasons. This is the public tier's whole justification.
	local three='[{"judge_type":"standard","score":0.95,"passed":true},{"judge_type":"adversarial","score":0.9,"passed":true},{"judge_type":"standard","score":0.8,"passed":false}]'

	_seed_confirmed "tier01" "org"
	run librarian_lesson_judge "$PROJECT_KEY" "tier01" "$three"
	[ "$status" -eq 0 ]
	[ "$(_status_of tier01)" = "approved" ]

	_seed_confirmed "tier02" "public"
	run librarian_lesson_judge "$PROJECT_KEY" "tier02" "$three"
	[ "$status" -eq 0 ]
	[ "$(_status_of tier02)" = "rejected" ]
}

@test "a rejected proposal keeps its file" {
	# librarian_lesson_seen scans proposals/ by artifact_id; deleting the file
	# would let the same artifact re-propose and re-pay tokens next scan.
	_seed_confirmed "rej01" "public"
	run librarian_lesson_judge "$PROJECT_KEY" "rej01" "$(_verdicts_split)"
	[ -f "$(librarian_lessons_dir "$PROJECT_KEY")/proposals/rej01.json" ]
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: the new tests FAIL — `librarian-lesson-judge.sh` does not exist.

- [ ] **Step 3: Write the judge lib**

Create `plugins/librarian/scripts/lib/librarian-lesson-judge.sh`:

```bash
#!/usr/bin/env bash
# Aggregate, gate, and record a jury verdict on a confirmed lesson.
#
# The agent orchestrates the jury; this file decides. Everything except
# subagent dispatch lives here so it can be tested.
#
# Librarian implements its own aggregate and gate rather than sourcing
# tribunal's. Reusing tribunal's published AGENT definitions is licensed by
# docs/adr/002-agent-definitions-are-shared-assets.md; sourcing its bash would
# be the hook-to-hook runtime coupling that ADR rules out.
#
# Exposes:
#   librarian_lesson_aggregate <verdicts_json>
#   librarian_lesson_gate <gate_policy> <verdicts_json> <aggregate> <threshold>
#   librarian_lesson_judge <key> <lesson_id> <verdicts_json>

# Mean of the judges' scores. Returns 1 on an empty panel.
#
# A plain mean, deliberately: per-criterion scores never reach this layer, so
# there is nothing to weight. See ecosystem-pht.
#
# Usage: librarian_lesson_aggregate <verdicts_json>
librarian_lesson_aggregate() {
	local verdicts="${1:-[]}"
	local n
	n=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || return 1
	[[ -z "$n" || "$n" -eq 0 ]] && return 1
	printf '%s' "$verdicts" | jq -r '[.[].score] | add / length' 2>/dev/null || return 1
}

# Decide pass/block from the panel and the aggregate.
#
# Echoes {"passed": bool, "reason": string}. Both conditions must hold: the
# jury must clear its policy AND the aggregate must clear the threshold.
#
# Usage: librarian_lesson_gate <gate_policy> <verdicts_json> <aggregate> <threshold>
librarian_lesson_gate() {
	local policy="${1:-majority}"
	local verdicts="${2:-[]}"
	local aggregate="${3:-0}"
	local threshold="${4:-0.75}"

	local count passed_count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	passed_count=$(printf '%s' "$verdicts" | jq '[.[] | select(.passed == true)] | length' 2>/dev/null) || passed_count=0

	local jury_ok=1 jury_reason=""
	case "$policy" in
		unanimous)
			if [[ "$count" -gt 0 && "$passed_count" -eq "$count" ]]; then
				jury_ok=0
			else
				jury_reason="jury_not_unanimous"
			fi
			;;
		majority)
			if [[ "$count" -gt 0 ]] && (( passed_count * 2 > count )); then
				jury_ok=0
			else
				jury_reason="jury_not_majority"
			fi
			;;
		*)
			printf '{"passed":false,"reason":"unknown_gate_policy"}'
			return 0
			;;
	esac

	if [[ "$jury_ok" -ne 0 ]]; then
		printf '{"passed":false,"reason":"%s"}' "$jury_reason"
		return 0
	fi

	# awk for the float comparison: bash cannot compare decimals.
	if awk -v s="$aggregate" -v t="$threshold" 'BEGIN { exit !(s >= t) }'; then
		printf '{"passed":true,"reason":"gate_passed"}'
	else
		printf '{"passed":false,"reason":"below_threshold"}'
	fi
	return 0
}

# Judge one confirmed lesson and record the outcome.
#
# Return codes are the interface the CLI and skill depend on:
#   0  a verdict was recorded (status is now approved or rejected)
#   1  usage or state error; nothing written
#   2  UNJUDGED — the panel was unusable; nothing written, lesson stays
#      confirmed, and the next run retries it
#
# 2 is not a failure. "Judged and failed" must stay distinct from "could not
# judge": the watermark has already advanced past this artifact, so treating a
# broken judge as a rejection would bury a good lesson permanently.
#
# Usage: librarian_lesson_judge <key> <lesson_id> <verdicts_json>
librarian_lesson_judge() {
	local key="$1"
	local lesson_id="$2"
	local verdicts="${3:-[]}"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local current_status visibility
	current_status=$(jq -r '.status // ""' "$path" 2>/dev/null)
	visibility=$(jq -r '.visibility // ""' "$path" 2>/dev/null)

	if [[ "$current_status" != "confirmed" ]]; then
		printf 'Lesson %s is not confirmed; its status is: %s\n' "$lesson_id" "$current_status" >&2
		return 1
	fi

	local rubric_id
	rubric_id=$(librarian_lesson_rubric_id_for_visibility "$visibility") || {
		printf 'Lesson %s has an unrecognized visibility: %s\n' "$lesson_id" "$visibility" >&2
		return 1
	}

	local verdict now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	if [[ -z "$rubric_id" ]]; then
		# private: no jury, no model call, straight through.
		verdict=$(jq -cn --arg t "$now" \
			'{rubric_id: null, gate_policy: null, score_threshold: null,
			  aggregate_score: null, passed: true, reason: "private_no_jury",
			  judges: []}') || return 1
	else
		# Every judge must have returned a usable verdict, or this candidate
		# is unjudged. With a two-judge panel under either policy, losing one
		# verdict means the gate cannot be decided at all.
		local usable
		usable=$(printf '%s' "$verdicts" | jq '
			if type != "array" or length == 0 then false
			else all(.[]; (.judge_type | type) == "string"
			              and (.score | type) == "number"
			              and (.passed | type) == "boolean")
			end' 2>/dev/null) || usable="false"
		[[ "$usable" != "true" ]] && return 2

		local rubric threshold policy aggregate gate
		rubric=$(librarian_lesson_rubric_get "$rubric_id") || return 1
		threshold=$(printf '%s' "$rubric" | jq -r '.score_threshold')
		policy=$(printf '%s' "$rubric" | jq -r '.gate_policy')

		aggregate=$(librarian_lesson_aggregate "$verdicts") || return 2
		gate=$(librarian_lesson_gate "$policy" "$verdicts" "$aggregate" "$threshold") || return 1

		verdict=$(jq -cn \
			--arg r "$rubric_id" --arg p "$policy" \
			--argjson th "$threshold" --argjson ag "$aggregate" \
			--argjson g "$gate" --argjson j "$verdicts" \
			'{rubric_id: $r, gate_policy: $p, score_threshold: $th,
			  aggregate_score: $ag, passed: $g.passed, reason: $g.reason,
			  judges: $j}') || return 1
	fi

	local new_status updated
	if [[ "$(printf '%s' "$verdict" | jq -r '.passed')" == "true" ]]; then
		new_status="approved"
	else
		new_status="rejected"
	fi

	updated=$(jq --arg s "$new_status" --arg t "$now" --argjson v "$verdict" \
		'.status = $s | .judged_at = $t | .verdict = $v' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	printf '%s\n' "$updated" > "$path"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: PASS, all tests.

- [ ] **Step 5: Prove the tier-separating test discriminates**

This is the test the whole public tier exists for. In a throwaway worktree,
change the public rubric's `gate_policy` from `unanimous` to `majority`:

```bash
git worktree add /tmp/lj-verify2 HEAD
# In /tmp/lj-verify2 only: plugins/librarian/config.json,
#   "lesson-promotion-public" -> "gate_policy": "majority"
bats test/bats/librarian-lesson-judge.bats
git worktree remove --force /tmp/lj-verify2
```

Expected: **"a three-judge panel with one dissenter separates the two tiers"
FAILS** — `tier02` would be approved. That test is the one that proves the
outcomes diverge; the two-judge cases reject under either policy and so cannot
detect this on their own.

Report which tests failed under the injection. If only the `.reason`
assertions moved and no `.status` did, say so plainly rather than reporting the
guard as proven.

- [ ] **Step 6: Run lint and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-lesson-judge.sh
git add plugins/librarian/scripts/lib/librarian-lesson-judge.sh \
        test/bats/librarian-lesson-judge.bats
```

Commit subject: `feat(librarian): judge a confirmed lesson and record it :gavel:`

---

### Task 3: The CLI surface

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-cli.sh`
- Test: `test/bats/librarian-lesson-judge.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_judge <key> <lesson_id> <verdicts_json>` with its 0/1/2 return codes (Task 2); `librarian_lesson_list_by_status <key> <status>` (already shipped).
- Produces: `librarian_cli lessons judge <id> <verdicts-json> [cwd]` and `librarian_cli lessons list --confirmed --json`.

`--json` is a small addition beyond the spec. The skill needs each candidate's
`visibility` to pick a rubric and to count publics for the pre-spend prompt;
without it the skill would parse a two-column text format and then call `show`
once per candidate. One machine-readable call replaces N+1 fragile ones.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-judge.bats`. Add to `setup()`:

```bash
	source "${PLUGIN_ROOT}/scripts/lib/librarian-cli.sh"
```

```bash
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: the eight new tests FAIL — `judge` is an unknown lessons action, and `--json` is refused as an unknown option.

- [ ] **Step 3: Add `--json` to the list verb**

In `librarian_cli_lessons_list`, add a `json=0` local, a `--json) json=1; shift ;;`
arm to the existing `while` loop before the `--*` catch-all, and branch the
output:

```bash
	if [[ "$json" -eq 1 ]]; then
		printf '%s' "$rows"
		return 0
	fi
```

Place that **before** the existing empty-check, so an empty set emits `[]`
rather than the prose empty-state the skill cannot parse.

- [ ] **Step 4: Add the judge verb**

Add to `librarian-cli.sh`, following the shape of the sibling verbs:

```bash
# Usage: librarian_cli_lessons_judge <lesson_id> <verdicts-json> [cwd]
#
# Verdicts come from the judge subagents the skill dispatched. Exit 2 means the
# candidate could not be judged and stays confirmed — distinct from a rejection,
# which is a real verdict and exits 0.
librarian_cli_lessons_judge() {
	local lesson_id="" verdicts="" cwd=""
	local positional=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--*)
				printf 'unknown option: %s\n' "$1" >&2
				return 1
				;;
			*)
				case "$positional" in
					0) lesson_id="$1" ;;
					1) verdicts="$1" ;;
					*) cwd="$1" ;;
				esac
				positional=$((positional + 1))
				shift
				;;
		esac
	done

	if [[ -z "$lesson_id" || -z "$verdicts" ]]; then
		printf 'usage: librarian_cli lessons judge <lesson_id> <verdicts-json> [cwd]\n'
		return 1
	fi

	local key
	key=$(_librarian_cli_project_key "$cwd")
	[[ -z "$key" ]] && { printf 'No project key resolvable from this directory.\n'; return 1; }

	librarian_lesson_judge "$key" "$lesson_id" "$verdicts"
	local rc=$?
	case "$rc" in
		0)
			printf 'Lesson %s is now %s.\n' "$lesson_id" \
				"$(jq -r '.status' "$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json")"
			;;
		2)
			printf 'Lesson %s could not be judged; it stays confirmed. Re-run to retry.\n' "$lesson_id"
			;;
	esac
	return $rc
}
```

Register it in `librarian_cli_lessons`'s `case`, after `unconfirm`:

```bash
		judge) librarian_cli_lessons_judge "$@" ;;
```

Source `librarian-lesson-judge.sh` and `librarian-lesson-rubric.sh` alongside
the existing lesson lib sources in `librarian-cli.sh`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bats test/bats/librarian-lesson-judge.bats && bats test/bats/librarian-cli.bats && bats test/bats/librarian-lesson-review.bats`
Expected: all PASS. Read each exit code directly — never through a pipe, which reports the pipe's last command.

- [ ] **Step 6: Prove the flag guard and the empty-array test discriminate**

In a throwaway worktree, separately: remove the `--*` arm from
`librarian_cli_lessons_judge` and confirm "lessons judge rejects an unknown
flag" fails; then move the `--json` early return *after* the empty-check and
confirm "lessons list --json on an empty set emits an empty array" fails.

- [ ] **Step 7: Run lint and commit**

```bash
npm run lint:check
shellcheck -S error -x plugins/librarian/scripts/lib/librarian-cli.sh
git add plugins/librarian/scripts/lib/librarian-cli.sh test/bats/librarian-lesson-judge.bats
```

Commit subject: `feat(librarian): surface judging on the lessons CLI :gavel:`

---

### Task 4: Assert the seam si6 left for this stage

**Files:**
- Test: `test/bats/librarian-lesson-review.bats` (append)

**Interfaces:**
- Consumes: `librarian_lesson_judge` (Task 2), `librarian_lesson_unconfirm` (already shipped).
- Produces: nothing. This task adds tests only.

`si6` promised that `unconfirm` would refuse whatever status this stage
introduced, automatically, through its catch-all — with no change to `unconfirm`
and no coordination between the stages. **Do not modify `librarian_lesson_unconfirm`.**
This task collects on that promise by asserting it.

- [ ] **Step 1: Write the tests**

Append to `test/bats/librarian-lesson-review.bats`. Reuse that file's existing
setup and seeding helpers; source `librarian-lesson-judge.sh` and
`librarian-lesson-rubric.sh` in its `setup()` if they are not already.

The existing helpers in that file are `_review_setup` (call it first, as every
test there does) and `_seed_pending`, which writes a `versioned` candidate and
echoes its id.

```bash
@test "unconfirm refuses an approved lesson, naming the status" {
	_review_setup
	local id
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "org"
	librarian_lesson_judge "$PROJECT_KEY" "$id" \
		'[{"judge_type":"standard","score":0.9,"passed":true},{"judge_type":"adversarial","score":0.8,"passed":true}]'

	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unrecognized status"* && "$output" == *"approved"* ]] || return 1
}

@test "unconfirm refuses a rejected lesson, naming the status" {
	_review_setup
	local id
	id=$(_seed_pending)
	librarian_lesson_confirm "$PROJECT_KEY" "$id" "public"
	librarian_lesson_judge "$PROJECT_KEY" "$id" \
		'[{"judge_type":"standard","score":0.95,"passed":true},{"judge_type":"adversarial","score":0.75,"passed":false}]'

	run librarian_lesson_unconfirm "$PROJECT_KEY" "$id"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unrecognized status"* && "$output" == *"rejected"* ]] || return 1
}
```

`_seed_pending` writes a `versioned` candidate, so confirming at `public` needs
no `--justification` — that flag is only required to convert scope to
`version_independent`.

- [ ] **Step 2: Run the tests**

Run: `bats test/bats/librarian-lesson-review.bats`
Expected: PASS. These pass on the first try — that is the point. `unconfirm`'s
catch-all already handles both statuses.

- [ ] **Step 3: Confirm the tests are not vacuous**

Both assert a non-zero exit, which several guards in this file can produce.
The message pin (`unrecognized status` plus the status name) is what makes them
discriminate. Verify in a throwaway worktree: change `unconfirm`'s catch-all to
`*) return 1 ;;` with no message, and confirm both tests fail.

- [ ] **Step 4: Commit**

```bash
git add test/bats/librarian-lesson-review.bats
```

Commit subject: `test(librarian): collect on si6's forward-safety promise :handshake:`

---

### Task 5: The skill route and the ADR

**Files:**
- Modify: `plugins/librarian/skills/librarian/SKILL.md`
- Create: `plugins/librarian/docs/adr/002-agent-definitions-are-shared-assets.md`

**Interfaces:**
- Consumes: `librarian_cli lessons list --confirmed --json`, `librarian_cli lessons show <id>`, `librarian_cli lessons judge <id> <verdicts-json>` (Task 3).
- Produces: nothing programmatic.

- [ ] **Step 1: Write the ADR**

Create `plugins/librarian/docs/adr/002-agent-definitions-are-shared-assets.md`:

```markdown
# ADR-002: Agent definitions are shared assets; hooks are not

## Status

Accepted.

## Context

CLAUDE.md states: "Plugins communicate by emitting events to the JSONL log —
they do not call each other directly. All plugins depend on the ecosystem
substrate; no plugin depends on another plugin directly."

Lesson judging (`ecosystem-4z8.3`) needs a jury. Tribunal ships three judge
agent definitions and the rubric vocabulary. The stage couples librarian and
tribunal in some direction no matter how it is arranged: either librarian
reaches for tribunal's judges, or tribunal reaches into librarian's
project-keyed proposal files and writes verdicts back into them.

## Decision

The invariant forbids **runtime** coupling — one plugin's hook or library
calling another's, which makes one plugin's failure another's. It does not
forbid reusing a **published agent definition** by name.

Librarian therefore owns the `judge` verb, both rubrics, the aggregate, and the
gate decision, and dispatches `tribunal-judge-standard` and
`tribunal-judge-adversarial` by name.

Librarian does **not** source any file under `plugins/tribunal/`. It implements
its own aggregate and gate — roughly twenty lines — rather than calling
`tribunal_aggregate` or `tribunal_gate_decide`.

## Rationale

An agent definition is declarative: a markdown file with frontmatter and a
prompt. It has no runtime surface, cannot fail at call time in a way that
propagates, and is resolved by the harness rather than by librarian. Depending
on one is closer to depending on a published schema than to calling another
plugin's code.

Sourcing tribunal's bash would be the real coupling: a change to
`tribunal_gate_decide`'s signature would break librarian silently, and
tribunal's own tests would not catch it.

Keeping the lifecycle in librarian also keeps `ecosystem-4z8.4`'s pool and
ledger in one plugin instead of splitting them across two.

## Consequences

A judge agent renamed or removed in tribunal breaks lesson judging at dispatch
time. That is a visible, loud failure at the moment a human invokes the verb —
not a silent one — and the "could not judge" path already handles it: the
candidate stays `confirmed` and nothing is written.

Librarian's gate logic can drift from tribunal's. Accepted deliberately: they
answer different questions. Tribunal gates an Actor's output with retry;
librarian gates a fixed artifact with none.
```

- [ ] **Step 2: Add the judge route to SKILL.md**

Add to the frontmatter `description`, in the sentence that lists the lesson
routes, so `judge` is discoverable: mention `/librarian lessons judge`.

Add this section after the existing `lessons` walk:

```markdown
For `lessons judge`, run the jury over confirmed candidates:

1. Call `librarian_cli lessons list --confirmed --json`. Each row carries `id`,
   `visibility`, and the full `candidate`. If the array is empty, tell the user
   there is nothing awaiting judgment and stop.
2. **Report the batch before spending anything.** Say how many candidates are
   confirmed and how many are `public`, and ask whether to proceed. This is the
   most expensive step in the pipeline. If the user declines, stop — nothing is
   written and every candidate stays `confirmed`.
3. For each candidate, in order:
   - **If `visibility` is `private`, dispatch no judges at all.** Call
     `librarian_cli lessons judge <id> '[]'` and move on. Private lessons run no
     jury; that is what makes cost scale with intent rather than artifact volume.
   - Otherwise spawn **both** `tribunal-judge-standard` and
     `tribunal-judge-adversarial` with the Task tool. Give each the candidate's
     `claim`, `rationale`, `evidence.resolution`, and `applies_to`, plus the
     rubric criteria for its visibility: for `org`, grounding / scope_accuracy /
     generality; for `public`, those three plus **disclosure** — does the text
     leak a credential, internal hostname, customer name, or proprietary detail?
   - Each judge returns a JSON object with `score`, `passed`, `judge_type`, and
     `feedback_summary`. Collect both into a JSON array **verbatim** — never
     summarize or reconstruct a judge's verdict.
   - Call `librarian_cli lessons judge <id> '<verdicts-json>'`. Record before
     moving to the next candidate, so an interrupted run costs at most one
     re-judgment.
4. **If either judge fails to return parseable JSON, do not invent a verdict and
   do not drop that judge.** Pass what you have to the CLI; it will exit 2, leave
   the candidate `confirmed`, and report that it could not be judged. Collect
   those ids and list them at the end so the user knows to re-run. A broken judge
   must never become a rejection — the artifact's watermark has already moved,
   so a false rejection buries a good lesson permanently.
5. Finish by reporting counts: approved, rejected, and could-not-judge.

`scope_accuracy` is the criterion that matters most on a `version_independent`
candidate. The schema guarantees such a lesson **carries** a justification; this
criterion asks whether it is **true**.
```

- [ ] **Step 3: Verify the docs lint and cross-references pass**

```bash
npm run lint:check
npm run test:schema
```

Expected: both exit 0. `check-references.mjs` validates that documents referenced
from other documents exist; a mistyped ADR path fails there.

- [ ] **Step 4: Run the full suite**

```bash
npm run test:ci
```

Expected: exit 0. Read the exit code directly, not through a pipe.

- [ ] **Step 5: Commit**

```bash
git add plugins/librarian/skills/librarian/SKILL.md \
        plugins/librarian/docs/adr/002-agent-definitions-are-shared-assets.md
```

Commit subject: `feat(librarian): walk the jury from the lessons skill :balance_scale:`

---

## Spec coverage

Every case in the spec's Testing section maps to a task:

| Spec test | Task |
|---|---|
| `private` reaches `approved` with no model call | 2 |
| `org` uses `lesson-promotion` + majority | 1, 2 |
| `public` uses `lesson-promotion-public` + unanimous | 1, 2 |
| a public candidate one judge blocks is rejected though the aggregate clears | 2 |
| one judge returning unparseable output leaves it `confirmed`, id reported | 2, 3 |
| a below-threshold candidate is rejected and keeps its file | 2 |
| `unconfirm` refuses `approved` and `rejected`, naming the status | 4 |
| re-running skips candidates that are not `confirmed` | 2 |
| both rubrics' weights sum to 1.00 | 1 |

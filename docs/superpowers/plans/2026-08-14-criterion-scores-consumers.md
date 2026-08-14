# Per-Criterion Scores — Consumer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tribunal's and librarian's rubric `weight` and `min_pass` values actually change outcomes, so a criterion can act as a floor that a strong weighted mean cannot average away.

**Architecture:** Judges gain a `criterion_scores` map on their output contract, keyed by **rubric** criterion name. Tribunal's `tribunal_aggregate` computes a real weighted mean from those scores and its gate blocks on any criterion below its `min_pass`, emitting the new `criterion_floor` reason. Librarian's parallel implementations gain the same two capabilities through widened signatures, which lets the public lesson tier trade its inert `unanimous` stand-in for a real `disclosure` floor.

**Tech Stack:** bash 3.2-compatible shell, `jq`, `awk`, bats, `@onlooker-community/schema` 2.12.0.

## Global Constraints

- **`@onlooker-community/schema` must be at `^2.12.0`.** 2.12.0 adds optional `criterion_scores` on `TribunalVerdictPayload` and the `criterion_floor` value in `tribunal.gate.blocked`'s `reason` enum plus optional `failed_criterion`. Task 1 is blocked until that version publishes.
- **Absent must never read as zero.** A judge that did not score a criterion must never be treated as one that scored `0.0`. Use `has()` or an explicit type test. **Specifically banned: defaulting a criterion score with `// 0`.** (Defaulting a missing *array* with `// []` is fine and appears in this plan — the ban is on scores.)
- **Look criterion names up as `.criterion_scores[$name]` with `--arg`/`$c.name`, never as a dotted path.** `path-traversal` and `edge-cases` already ship in agent contracts. `jq '.criterion_scores.path-traversal'` is a **compile error**: `jq` exits 3 with empty stdout, which `awk` then reads as `0`, failing toward blocking on a name the rubric author is entitled to write.
- **A floor on a criterion that no judge scored must be surfaced, never silently passed.** That is this design's own failure mode one layer down.
- **Tribunal and librarian each implement their own aggregate and gate. Do not unify them.** `plugins/librarian/docs/adr/002-agent-definitions-are-shared-assets.md` licenses reusing tribunal's *agent definitions* but rules out sourcing its bash. The near-duplicate jq between Tasks 2/3 and Task 4 is **plan-mandated**, not an oversight — a reviewer must not flag it as a DRY violation.
- **macOS bash 3.2:** a failing **non-final** `[[ ]]` does **not** fail a bats test. Use `[ ]` for assertions, or append `|| return 1`. A bats `[[ =~ ]]` regex must be an **unquoted variable**.
- **Use `run --separate-stderr`** whenever a test asserts empty stdout alongside a stderr message. Plain `run` merges them and the assertion becomes unsatisfiable.
- **Every test must be falsifiable.** Before committing a task, delete the guard under test and confirm a test fails. The recurring defect in this epic — seven-plus instances — is a *downstream* guard making an *upstream* guard's test pass whether or not the upstream guard exists.
- All hooks are bash; runtime artifacts live under `$ONLOOKER_DIR`, never a hardcoded `~/.onlooker`; ULIDs via each plugin's own `*-ulid.sh`; config defaults in `config.json` with overrides per ADR-004; the emitter fails open per ADR-005.
- Tests are bats under an isolated temp home per `.claude/skills/writing-tests`. Run `npm run test:ci` before the PR.
- **PR-only. Never push to `main`.** Branch from `feat/criterion-scores`, which already carries the corrected spec.

---

## Background the tasks assume

Verified against the repo on 2026-08-14. Trust this section over the spec's prose — the spec was corrected today precisely because its descriptions of code were wrong, and two of its claims were **still** wrong after that correction (noted below).

**Tribunal's default rubric** (`plugins/tribunal/config.json`, `.tribunal.rubric.builtins[0]`):

| criterion | weight | min_pass |
|---|---|---|
| correctness | 0.4 | 0.7 |
| completeness | 0.3 | 0.7 |
| safety | 0.2 | **0.8** |
| clarity | 0.1 | 0.5 |

`judge_types: ["standard","adversarial"]`, `gate_policy: "majority"`, `aggregation_method: "weighted_mean"`, `score_threshold: 0.75`.

**Librarian's rubrics** (`plugins/librarian/config.json`, `.librarian.lesson_judging.rubrics` — an **array**, looked up by `.id`):

- `lesson-promotion` — grounding 0.45/0.7, scope_accuracy 0.35/0.7, generality 0.20/0.6; `gate_policy: majority`
- `lesson-promotion-public` — grounding 0.32/0.7, scope_accuracy 0.24/0.7, generality 0.14/0.6, **disclosure 0.30/0.9**; `gate_policy: unanimous`

Both declare `judge_types: ["standard","adversarial"]`.

**The three judge agents report their own investigative lenses, not rubric criteria:**

| agent | `criteria_evaluated` example | has a rubric section? |
|---|---|---|
| `tribunal-judge-standard.md` | `["correctness","completeness","clarity"]` | yes |
| `tribunal-judge-adversarial.md` | `["edge-cases","concurrency","idempotency"]` | **no** |
| `tribunal-judge-security.md` | `["injection","secrets","path-traversal"]` | **no** |

**Two corrections to the corrected spec.** It says `-security` already receives the rubric — it does not; the gap is two agents. And it implies `criteria_evaluated` is rubric-derived — it is not, for any of the three. Task 5 fixes the spec text.

**Consequence:** on the default panel, `safety` — the criterion with the highest floor — appears in **no** judge's output. Its floor would silently never fire. The resolution this plan adopts:

> `criteria_evaluated` keeps its present meaning — the agent's own investigative lenses — and is left **unchanged**. `criterion_scores` is a **separate** map keyed by **rubric** criterion names. Every judge scores every rubric criterion it was given; its lens list is how it got there.

**Callers.** `tribunal_aggregate` and `tribunal_gate_decide` are called only from `plugins/tribunal/skills/tribunal/SKILL.md` (steps 5 and 7). `librarian_lesson_aggregate` and `librarian_lesson_gate` are called only from `librarian_lesson_judge` in the same file. Both new parameters are **optional and trailing**, so no caller breaks.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `package.json` | schema dependency floor | 1 |
| `plugins/tribunal/agents/tribunal-judge-standard.md` | output contract gains `criterion_scores` | 1 |
| `plugins/tribunal/agents/tribunal-judge-adversarial.md` | gains a rubric section + `criterion_scores` | 1 |
| `plugins/tribunal/agents/tribunal-judge-security.md` | gains a rubric section + `criterion_scores` | 1 |
| `test/bats/tribunal-judge-agents.bats` | **new** — contract tests over the shipped agent files | 1 |
| `plugins/tribunal/scripts/lib/tribunal-aggregate.sh` | real `weighted_mean` | 2 |
| `test/bats/tribunal-aggregate.bats` | aggregation tests (10 existing) | 2 |
| `plugins/tribunal/scripts/lib/tribunal-gate.sh` | `min_pass` floor, `criterion_floor` reason | 3 |
| `test/bats/tribunal-gate.bats` | gate tests (10 existing) | 3 |
| `plugins/tribunal/skills/tribunal/SKILL.md` | pass the rubric; emit `failed_criterion` | 3 |
| `plugins/librarian/scripts/lib/librarian-lesson-judge.sh` | rubric-aware aggregate + gate | 4 |
| `test/bats/librarian-lesson-judge.bats` | judging tests (43 existing) | 4 |
| `plugins/librarian/config.json` | public tier `unanimous` → `majority` | 5 |
| `plugins/librarian/scripts/lib/librarian-lesson-rubric.sh` | the "inert" comment is no longer true | 5 |
| `plugins/librarian/skills/librarian/SKILL.md` | judges must return `criterion_scores` | 5 |
| `docs/superpowers/specs/2026-08-11-lesson-judging-design.md` | the `unanimous` stand-in never worked | 5 |
| `docs/superpowers/specs/2026-08-14-criterion-scores-design.md` | `-security` correction | 5 |

---

### Task 1: Judges emit `criterion_scores`

**Files:**
- Modify: `package.json` (the `@onlooker-community/schema` dependency)
- Modify: `plugins/tribunal/agents/tribunal-judge-standard.md:26-47`
- Modify: `plugins/tribunal/agents/tribunal-judge-adversarial.md:34-51`
- Modify: `plugins/tribunal/agents/tribunal-judge-security.md:30-47`
- Test: `test/bats/tribunal-judge-agents.bats` (new file)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the judge output contract every later task assumes —
  `criterion_scores` is an **object** mapping a **rubric criterion name** to a number in `[0,1]`. It is **optional**: a judge that cannot score a criterion omits that key rather than sending `0`. `criteria_evaluated` is unchanged and remains the agent's own lens list.

**BLOCKED UNTIL** `@onlooker-community/schema` 2.12.0 is published to npm. Check with `npm view @onlooker-community/schema version`. If it still reports `2.11.0`, stop and report BLOCKED — do not hand-edit a version that cannot install.

- [ ] **Step 1: Write the failing contract test**

Create `test/bats/tribunal-judge-agents.bats`:

```bash
#!/usr/bin/env bats

setup() {
	source "${BATS_TEST_DIRNAME}/../helpers/setup.bash"
	setup_test_env

	AGENTS_DIR="${REPO_ROOT}/plugins/tribunal/agents"
}

# Extract the first fenced ```json block from an agent definition.
_agent_json() {
	awk '/^```json/ { f = 1; next } /^```/ { if (f) exit } f' "$1"
}

@test "every judge agent's example verdict carries criterion_scores" {
	local agent json
	for agent in standard adversarial security; do
		json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-${agent}.md")
		[ -n "$json" ] || return 1
		printf '%s' "$json" | jq -e 'has("criterion_scores")' >/dev/null || return 1
	done
}

@test "criterion_scores is an object of numbers in [0,1], not an array" {
	local agent json
	for agent in standard adversarial security; do
		json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-${agent}.md")
		printf '%s' "$json" | jq -e '
			(.criterion_scores | type) == "object"
			and (.criterion_scores | length) > 0
			and all(.criterion_scores[]; type == "number" and . >= 0 and . <= 1)
		' >/dev/null || return 1
	done
}

@test "criterion_scores is keyed by rubric criteria, not by the agent's own lenses" {
	# The default rubric's criteria are the only legal keys. This is the whole
	# point: an agent keying by its own lens names (edge-cases, injection)
	# produces scores no aggregator can ever match to a floor.
	local rubric_names json agent
	rubric_names=$(jq -c '[.tribunal.rubric.builtins[0].criteria[].name]' \
		"${REPO_ROOT}/plugins/tribunal/config.json")

	for agent in standard adversarial security; do
		json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-${agent}.md")
		printf '%s' "$json" | jq -e --argjson want "$rubric_names" '
			[.criterion_scores | keys[]] | all(. as $k | $want | index($k) != null)
		' >/dev/null || return 1
	done
}

@test "every judge agent scores safety, the criterion with the highest floor" {
	# safety carries min_pass 0.8 and appeared in NO agent contract before this
	# change, so its floor could never fire. Regression guard.
	local agent json
	for agent in standard adversarial security; do
		json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-${agent}.md")
		printf '%s' "$json" | jq -e '.criterion_scores | has("safety")' >/dev/null || return 1
	done
}

@test "adversarial and security agents document the rubric they must score" {
	local agent
	for agent in adversarial security; do
		grep -qi 'rubric' "${AGENTS_DIR}/tribunal-judge-${agent}.md" || return 1
	done
}

@test "criteria_evaluated keeps each agent's own investigative lenses" {
	# Deliberately NOT unified with criterion_scores. If a future edit collapses
	# the two, the adversarial agent stops reporting what it actually probed.
	local json
	json=$(_agent_json "${AGENTS_DIR}/tribunal-judge-adversarial.md")
	printf '%s' "$json" | jq -e '
		(.criteria_evaluated | index("edge-cases")) != null
	' >/dev/null
}

@test "the schema dependency admits criterion_scores" {
	# criterion_scores and the criterion_floor reason land in 2.12.0. On ^2.11.0
	# the runtime emitter rejects the payload wherever the package resolves.
	local range
	range=$(jq -r '.dependencies["@onlooker-community/schema"] // .devDependencies["@onlooker-community/schema"]' \
		"${REPO_ROOT}/package.json")
	[ "$range" = "^2.12.0" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats test/bats/tribunal-judge-agents.bats`
Expected: FAIL — 6 of 7 tests fail. No agent has `criterion_scores` yet, and the dependency is `^2.11.0`. The `criteria_evaluated` test passes already, which is correct: it guards behavior that must **not** change.

- [ ] **Step 3: Bump the schema dependency**

```bash
npm install @onlooker-community/schema@^2.12.0
```

Confirm `package.json` reads `"@onlooker-community/schema": "^2.12.0"` and `package-lock.json` resolves `2.12.0`.

- [ ] **Step 4: Add `criterion_scores` to the standard judge**

In `plugins/tribunal/agents/tribunal-judge-standard.md`, inside the ```json block, add the field after `criteria_evaluated`:

```json
  "criteria_evaluated": ["correctness", "completeness", "clarity"],
  "criterion_scores": {
    "correctness": 0.9,
    "completeness": 0.75,
    "safety": 0.85,
    "clarity": 0.8
  },
```

Then, immediately after the "Required fields" paragraph (currently line 43), add:

```markdown
`criterion_scores` maps **each criterion name from the rubric you were given** to your score for it in `[0,1]`. This is separate from `criteria_evaluated`, which lists the dimensions *you* chose to investigate — the rubric's criteria are what the orchestrator weights and floors.

Score every rubric criterion you can judge. **Omit any criterion you genuinely cannot assess — do not send `0` for it.** A `0` means "I assessed this and it failed"; an omission means "I did not assess this." The orchestrator treats them very differently: a `0` on a criterion with a floor blocks the task outright, while an omission is reported as a coverage gap.
```

- [ ] **Step 5: Add a rubric section and `criterion_scores` to the adversarial judge**

In `plugins/tribunal/agents/tribunal-judge-adversarial.md`, add to the ```json block after `criteria_evaluated`:

```json
  "criteria_evaluated": ["edge-cases", "concurrency", "idempotency"],
  "criterion_scores": {
    "correctness": 0.5,
    "completeness": 0.6,
    "safety": 0.55,
    "clarity": 0.8
  },
```

Then add this section immediately before `## Output format`:

```markdown
## Scoring against the rubric

You are given a rubric with named criteria, each carrying a weight and a
`min_pass` floor. Your falsification work is how you form a judgment; the
rubric's criteria are how you report it.

Report a score in `[0,1]` for every rubric criterion in `criterion_scores`,
keyed by the rubric's own names. Your `criteria_evaluated` list stays what it
has always been — the dimensions you probed (edge cases, concurrency,
idempotency). The two lists are not expected to match.

`safety` in particular is a criterion you are well placed to score and no other
default judge covers. A crash on malformed input, a non-idempotent migration, a
race that corrupts state — those are safety findings, and this is where they
belong.

**Omit any criterion you cannot assess rather than scoring it `0`.** A `0` says
you assessed it and it failed, which on a criterion with a floor blocks the
task by itself.
```

- [ ] **Step 6: Add a rubric section and `criterion_scores` to the security judge**

In `plugins/tribunal/agents/tribunal-judge-security.md`, add to the ```json block after `criteria_evaluated`:

```json
  "criteria_evaluated": ["injection", "secrets", "path-traversal"],
  "criterion_scores": {
    "correctness": 0.7,
    "completeness": 0.6,
    "safety": 0.2,
    "clarity": 0.75
  },
```

Then add this section immediately before `## Output format`:

```markdown
## Scoring against the rubric

You are given a rubric with named criteria, each carrying a weight and a
`min_pass` floor. Your findings are how you form a judgment; the rubric's
criteria are how you report it.

Report a score in `[0,1]` for every rubric criterion in `criterion_scores`,
keyed by the rubric's own names. Your `criteria_evaluated` list stays what it
has always been — the dimensions you swept (injection, secrets, path
traversal). The two lists are not expected to match.

`safety` is where your findings land. It carries the highest floor in the
default rubric, and a single unresolved injection or leaked credential should
put your `safety` score below it.

**Omit any criterion you cannot assess rather than scoring it `0`.** A `0` says
you assessed it and it failed, which on a criterion with a floor blocks the
task by itself.
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bats test/bats/tribunal-judge-agents.bats`
Expected: PASS, 7/7.

- [ ] **Step 8: Prove the tests are falsifiable**

In a scratch (uncommitted) edit, delete the `"safety"` key from `tribunal-judge-adversarial.md`'s `criterion_scores`. Re-run: the "every judge agent scores safety" test must fail. Restore it. Then change one `criterion_scores` key in the security agent to `"injection"` and confirm the rubric-keys test fails. Restore. **Report both results in your report file.**

- [ ] **Step 9: Verify the whole suite still passes**

Run: `npm run test:ci`
Expected: exit 0. Read the exit code directly with `$?`, never through a pipe.

- [ ] **Step 10: Commit**

```bash
git add package.json package-lock.json plugins/tribunal/agents/ test/bats/tribunal-judge-agents.bats
git commit -m "feat(tribunal): have judges score the rubric's criteria :straight_ruler:"
```

---

### Task 2: `weighted_mean` becomes real

**Files:**
- Modify: `plugins/tribunal/scripts/lib/tribunal-aggregate.sh:1-59`
- Test: `test/bats/tribunal-aggregate.bats`

**Interfaces:**
- Consumes: the `criterion_scores` contract from Task 1.
- Produces: `tribunal_aggregate <method> <verdicts_json> [<rubric_json>]` — signature **unchanged**, third parameter now used instead of discarded. For `weighted_mean` with usable scores it echoes the weighted mean; otherwise it echoes the plain mean of `.score`, exactly as today.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/tribunal-aggregate.bats`:

```bash
# Two criteria with deliberately unequal weights, so weighted_mean and mean
# cannot coincide. Judge A is strong on the heavy criterion, weak on the light
# one; judge B is the reverse.
RUBRIC_UNEQUAL='{"criteria":[{"name":"correctness","weight":0.9,"min_pass":0.7},{"name":"clarity","weight":0.1,"min_pass":0.5}]}'
SCORED='[
  {"judge_id":"a","score":0.5,"criterion_scores":{"correctness":1.0,"clarity":0.0}},
  {"judge_id":"b","score":0.5,"criterion_scores":{"correctness":1.0,"clarity":0.0}}
]'

@test "weighted_mean differs from mean when weights are unequal" {
	# mean of .score is 0.5 for both judges. The weighted mean is
	# 0.9*1.0 + 0.1*0.0 = 0.9. If these come out equal, weights are still inert.
	local w m
	w=$(tribunal_aggregate "weighted_mean" "$SCORED" "$RUBRIC_UNEQUAL")
	m=$(tribunal_aggregate "mean" "$SCORED" "$RUBRIC_UNEQUAL")
	awk -v a="$w" -v b="$m" 'BEGIN { exit !(a != b) }' || return 1
	awk -v a="$w" 'BEGIN { exit !(a > 0.89 && a < 0.91) }'
}

@test "weighted_mean averages judges within a criterion before weighting" {
	local out
	out=$(tribunal_aggregate "weighted_mean" '[
	  {"judge_id":"a","score":0.5,"criterion_scores":{"correctness":1.0,"clarity":1.0}},
	  {"judge_id":"b","score":0.5,"criterion_scores":{"correctness":0.0,"clarity":1.0}}
	]' "$RUBRIC_UNEQUAL")
	# correctness mean 0.5, clarity mean 1.0 → 0.9*0.5 + 0.1*1.0 = 0.55
	awk -v a="$out" 'BEGIN { exit !(a > 0.549 && a < 0.551) }'
}

@test "weighted_mean degrades to mean when no verdict carries criterion_scores" {
	# Every verdict emitted before Task 1 shipped looks like this.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.8},{"judge_id":"b","score":0.6}]' "$RUBRIC_UNEQUAL")
	awk -v a="$out" 'BEGIN { exit !(a > 0.699 && a < 0.701) }'
}

@test "an absent criterion is skipped, not counted as zero" {
	# clarity is absent everywhere. If absence read as 0 the answer would be
	# 0.9*1.0 + 0.1*0.0 = 0.9. Skipping it renormalizes to 0.9/0.9 = 1.0.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.5,"criterion_scores":{"correctness":1.0}}]' \
		"$RUBRIC_UNEQUAL")
	awk -v a="$out" 'BEGIN { exit !(a > 0.999 && a < 1.001) }'
}

@test "a criterion scored at zero is honored, not treated as absent" {
	# The mirror of the previous test, and the one that catches a `// 0` fix
	# that "passes" the absence test by accident.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.5,"criterion_scores":{"correctness":0.0}}]' \
		"$RUBRIC_UNEQUAL")
	awk -v a="$out" 'BEGIN { exit !(a >= 0 && a < 0.001) }'
}

@test "weights that do not sum to 1.0 are normalized" {
	# tribunal_rubric_validate rejects such a rubric, but librarian's loader
	# validates nothing and hands its rubric straight through. Normalizing here
	# means the two paths cannot disagree.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.1,"criterion_scores":{"correctness":1.0,"clarity":0.0}}]' \
		'{"criteria":[{"name":"correctness","weight":1.8,"min_pass":0.7},{"name":"clarity","weight":0.2,"min_pass":0.5}]}')
	# 1.8*1.0 + 0.2*0.0 = 1.8, over a weight sum of 2.0 → 0.9
	awk -v a="$out" 'BEGIN { exit !(a > 0.899 && a < 0.901) }'
}

@test "a hyphenated criterion name scores correctly" {
	# A dotted jq path would be a COMPILE error here: exit 3, empty stdout,
	# which awk reads as 0.
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.2,"criterion_scores":{"path-traversal":1.0}}]' \
		'{"criteria":[{"name":"path-traversal","weight":1.0,"min_pass":0.5}]}')
	awk -v a="$out" 'BEGIN { exit !(a > 0.999 && a < 1.001) }'
}

@test "weighted_mean falls back to mean when the rubric is absent" {
	local out
	out=$(tribunal_aggregate "weighted_mean" "$SCORED")
	awk -v a="$out" 'BEGIN { exit !(a > 0.499 && a < 0.501) }'
}

@test "a non-number criterion score is ignored rather than poisoning the mean" {
	local out
	out=$(tribunal_aggregate "weighted_mean" \
		'[{"judge_id":"a","score":0.5,"criterion_scores":{"correctness":1.0,"clarity":"n/a"}}]' \
		"$RUBRIC_UNEQUAL")
	awk -v a="$out" 'BEGIN { exit !(a > 0.999 && a < 1.001) }'
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/tribunal-aggregate.bats`
Expected: FAIL — the new weighted tests fail because `weighted_mean` currently shares the `mean` branch. The degrade and fallback tests pass already; that is correct, since they pin behavior that must survive.

- [ ] **Step 3: Implement the real weighted mean**

Replace the header comment block at `plugins/tribunal/scripts/lib/tribunal-aggregate.sh:18-23` with:

```bash
# weighted_mean uses *rubric criterion weights*: average the judges' scores on
# each criterion, weight each criterion's mean, and normalize by the weights
# actually used. A criterion no judge scored contributes nothing and its weight
# is excluded from the denominator — absence is not a zero. When no criterion
# has any score (every verdict emitted before judges shipped criterion_scores),
# weighted_mean degrades to mean rather than collapsing to 0.
```

Replace the function body's `_rubric` handling and the `mean|weighted_mean` branch:

```bash
tribunal_aggregate() {
	local method="${1:-mean}"
	local verdicts="${2:-[]}"
	local rubric="${3:-}"
	[ -z "$rubric" ] && rubric='{}'

	local count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" -eq 0 ]] && { printf '0'; return 0; }

	case "$method" in
		mean)
			printf '%s' "$verdicts" | jq -r '[.[].score] | add / length'
			;;
		weighted_mean)
			local weighted
			weighted=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
				. as $v
				| [ ($rubric.criteria // [])[]
				    | select((.name | type) == "string" and (.weight | type) == "number")
				    | . as $c
				    | ([ $v[]
				         | select((.criterion_scores | type) == "object")
				         | select(.criterion_scores | has($c.name))
				         | .criterion_scores[$c.name]
				         | select(type == "number") ]) as $scores
				    | select(($scores | length) > 0)
				    | { w: $c.weight, m: (($scores | add) / ($scores | length)) } ]
				| (map(.w) | add) as $den
				| if length == 0 or $den == null or $den <= 0 then empty
				  else (map(.w * .m) | add) / $den
				  end
			' 2>/dev/null)
			if [ -n "$weighted" ]; then
				printf '%s' "$weighted"
			else
				# No criterion carried a usable score — degrade to mean.
				printf '%s' "$verdicts" | jq -r '[.[].score] | add / length'
			fi
			;;
		median)
```

Leave `median`, `min`, and the unknown-method fallback exactly as they are.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/bats/tribunal-aggregate.bats`
Expected: PASS, 19/19.

- [ ] **Step 5: Prove the guards are falsifiable**

Three scratch (uncommitted) edits, each reverted after checking:

1. Change `select(.criterion_scores | has($c.name))` to `select(true)` and `.criterion_scores[$c.name]` to `(.criterion_scores[$c.name] // 0)`. The "absent criterion is skipped" test must fail. **This is the exact regression the `// 0` ban exists to prevent.**
2. Change `.criterion_scores[$c.name]` to `.criterion_scores[$c.name] | tostring | tonumber` — the hyphenated-name test must still pass (proving the bracket lookup, not the name, is what matters). Then change the lookup to a dotted `.criterion_scores.correctness` and confirm the hyphenated test fails.
3. Delete `/ $den` (dividing by nothing). The normalization test must fail.

**Report all three results in your report file.**

- [ ] **Step 6: Verify the whole suite**

Run: `npm run test:ci`
Expected: exit 0, read from `$?` directly.

- [ ] **Step 7: Commit**

```bash
git add plugins/tribunal/scripts/lib/tribunal-aggregate.sh test/bats/tribunal-aggregate.bats
git commit -m "feat(tribunal): make weighted_mean weight something :straight_ruler:"
```

---

### Task 3: `min_pass` becomes enforceable

**Files:**
- Modify: `plugins/tribunal/scripts/lib/tribunal-gate.sh:1-112`
- Modify: `plugins/tribunal/skills/tribunal/SKILL.md:117-124`
- Test: `test/bats/tribunal-gate.bats`

**Interfaces:**
- Consumes: the `criterion_scores` contract from Task 1.
- Produces: `tribunal_gate_decide <policy> <verdicts> <aggregated_score> <score_threshold> <meta> <dissent_score> <dissent_threshold> [<rubric_json>]` — an **eighth, optional, trailing** parameter. When a criterion's mean falls below its `min_pass`, it echoes `{"passed":false,"reason":"criterion_floor","failed_criterion":"<name>"}`. All existing reasons and their precedence are unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/tribunal-gate.bats`:

```bash
RUBRIC_FLOOR='{"criteria":[{"name":"correctness","weight":0.5,"min_pass":0.7},{"name":"safety","weight":0.5,"min_pass":0.8}]}'

@test "a criterion below its floor blocks even when score and jury both pass" {
	# This is the property that does not exist today: aggregate 0.82 clears the
	# 0.75 threshold, both judges passed, and the gate blocks anyway.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.3}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == false' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "a criterion at exactly its floor passes" {
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.7,"safety":0.8}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.7,"safety":0.8}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "absent criterion_scores never block" {
	# Every verdict emitted before Task 1 shipped. Treating absence as violation
	# would make every pre-upgrade judge fail every rubric carrying a floor.
	local out
	out=$(tribunal_gate_decide "majority" "$ALL_PASSED" "0.82" "0.75" \
		"$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}

@test "a criterion scored exactly zero does block" {
	# The mirror of the previous test. A fix that conflates absent with zero
	# passes one of these two and fails the other.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.0}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9,"safety":0.0}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "criterion_floor"' >/dev/null || return 1
	printf '%s' "$out" | jq -e '.failed_criterion == "safety"' >/dev/null
}

@test "a hyphenated criterion name gates correctly" {
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"path-traversal":0.1}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"path-traversal":0.1}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" \
	'{"criteria":[{"name":"path-traversal","weight":1.0,"min_pass":0.5}]}')
	printf '%s' "$out" | jq -e '.failed_criterion == "path-traversal"' >/dev/null
}

@test "low_score still wins over criterion_floor" {
	# Precedence matters for the retry digest: if the aggregate missed the
	# threshold, that is the more actionable thing to tell the Actor.
	local out
	out=$(tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.20,"passed":true,"criterion_scores":{"correctness":0.1,"safety":0.1}},
	  {"judge_id":"b","score":0.20,"passed":true,"criterion_scores":{"correctness":0.1,"safety":0.1}}
	]' "0.20" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR")
	printf '%s' "$out" | jq -e '.reason == "low_score"' >/dev/null
}

@test "a floor on a criterion no judge scored is reported on stderr" {
	# The adversarial-judge gap: safety carries the highest floor and appeared
	# in no agent contract. Silently passing a floor nobody scored is this
	# design's own failure mode one layer down.
	run --separate-stderr tribunal_gate_decide "majority" '[
	  {"judge_id":"a","score":0.85,"passed":true,"criterion_scores":{"correctness":0.9}},
	  {"judge_id":"b","score":0.80,"passed":true,"criterion_scores":{"correctness":0.9}}
	]' "0.82" "0.75" "$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR"
	printf '%s' "$output" | jq -e '.passed == true' >/dev/null || return 1
	local re='safety'
	[[ "$stderr" =~ $re ]]
}

@test "no unscored-criterion warning when no judge scored anything" {
	# The pre-upgrade fleet must not spew a warning on every single gate.
	run --separate-stderr tribunal_gate_decide "majority" "$ALL_PASSED" "0.82" "0.75" \
		"$NO_META" "0.05" "0.25" "$RUBRIC_FLOOR"
	[ -z "$stderr" ]
}

@test "the gate still works with no rubric at all" {
	local out
	out=$(tribunal_gate_decide "majority" "$ALL_PASSED" "0.82" "0.75" "$NO_META" "0.05" "0.25")
	printf '%s' "$out" | jq -e '.passed == true' >/dev/null
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/tribunal-gate.bats`
Expected: FAIL — the floor tests fail because no floor exists. The "absent never blocks", "no rubric" and "low_score wins" tests pass already, pinning behavior that must survive.

- [ ] **Step 3: Implement the floor**

In `plugins/tribunal/scripts/lib/tribunal-gate.sh`, extend the header comment's reason list (line 17) to:

```bash
#   reason is one of: low_score | meta_override | bias_detected | dissent_unresolved
#                   | criterion_floor  (with failed_criterion naming the criterion)
```

Add the eighth parameter after line 29:

```bash
	local dissent_threshold="${7:-0.25}"
	local rubric="${8:-}"
	[ -z "$rubric" ] && rubric='{}'
```

Then insert this block immediately **after** the `score_ok` computation (currently line 93) and **before** the `if [[ "$jury_ok" -eq 0 && "$score_ok" -eq 0 ]]` check:

```bash
	# Per-criterion floors. A criterion whose mean across the judges that scored
	# it falls below min_pass blocks regardless of the aggregate or the policy —
	# that is the whole point of a floor.
	#
	# A criterion no judge scored is NOT a violation: absence is not a zero, and
	# treating it as one would fail every verdict emitted before judges shipped
	# criterion_scores. It is reported on stderr instead, because a floor nobody
	# scores is a silent hole in the rubric.
	local floor_failed unscored_floors any_scored
	any_scored=$(printf '%s' "$verdicts" | jq -r '
		[.[] | select((.criterion_scores | type) == "object")
		     | select((.criterion_scores | length) > 0)] | length > 0
	' 2>/dev/null) || any_scored="false"

	floor_failed=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
		. as $v
		| [ ($rubric.criteria // [])[]
		    | select((.name | type) == "string" and (.min_pass | type) == "number")
		    | . as $c
		    | ([ $v[]
		         | select((.criterion_scores | type) == "object")
		         | select(.criterion_scores | has($c.name))
		         | .criterion_scores[$c.name]
		         | select(type == "number") ]) as $scores
		    | select(($scores | length) > 0)
		    | select((($scores | add) / ($scores | length)) < $c.min_pass)
		    | $c.name ]
		| first // empty
	' 2>/dev/null) || floor_failed=""

	if [[ "$any_scored" == "true" ]]; then
		unscored_floors=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
			. as $v
			| [ ($rubric.criteria // [])[]
			    | select((.name | type) == "string" and (.min_pass | type) == "number")
			    | . as $c
			    | select([ $v[]
			               | select((.criterion_scores | type) == "object")
			               | select(.criterion_scores | has($c.name))
			               | .criterion_scores[$c.name]
			               | select(type == "number") ] | length == 0)
			    | $c.name ]
			| join(", ")
		' 2>/dev/null) || unscored_floors=""
		if [[ -n "$unscored_floors" ]]; then
			printf 'tribunal-gate: no judge scored these criteria, so their min_pass floors did not apply: %s\n' \
				"$unscored_floors" >&2
		fi
	fi
```

Finally, change the blocking-reason selection (currently lines 100-111) so the floor sits between `low_score` and the jury reasons:

```bash
	# Pick the most informative blocking reason. low_score first: if the
	# aggregate missed the threshold, that is the more actionable thing to tell
	# the Actor than any single criterion.
	if [[ "$score_ok" -ne 0 ]]; then
		printf '{"passed":false,"reason":"low_score"}'
	elif [[ -n "$floor_failed" ]]; then
		printf '{"passed":false,"reason":"criterion_floor","failed_criterion":"%s"}' "$floor_failed"
	elif [[ "$jury_ok" -ne 0 ]]; then
		if [[ "$meta_override" == "reject" ]]; then
			printf '{"passed":false,"reason":"meta_override"}'
		else
			printf '{"passed":false,"reason":"dissent_unresolved"}'
		fi
	else
		printf '{"passed":true}'
	fi
```

and delete the now-redundant early `if [[ "$jury_ok" -eq 0 && "$score_ok" -eq 0 ]]` pass block at lines 95-98, since the `else` arm above covers it. **Both a floor failure and a jury failure now reach this chain, so the old two-condition early return would have let a floor failure through.**

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bats test/bats/tribunal-gate.bats`
Expected: PASS, 19/19.

- [ ] **Step 5: Wire the reason through the orchestration walk**

In `plugins/tribunal/skills/tribunal/SKILL.md`, replace the step 7 code block (lines 118-121) with:

```bash
policy=$(printf '%s' "$rubric" | jq -r '.gate_policy // "majority"')
gate=$(tribunal_gate_decide "$policy" "$verdicts" "$aggregated" "$threshold" "$meta" "$dissent" "$dissent_threshold" "$rubric")
```

and replace the prose at line 122 with:

```markdown
   If `gate.passed == true`, emit `tribunal.gate.passed` with `final_score: aggregated` and break the loop with outcome `accepted`. Otherwise emit `tribunal.gate.blocked` with the `reason`, `will_retry: (iteration_number + 1 < max_iterations)`, and `retry_iteration_number` if retrying. **When `reason` is `criterion_floor`, copy `gate.failed_criterion` onto the event payload as `failed_criterion`** — without it the log records that a floor blocked but not which one. Persist `gate.json` either way.

   A `criterion_floor` block means the aggregate *cleared* its threshold and one criterion still failed its floor. Say so when you report it: "blocked on `safety` (0.30 < 0.80) despite an overall 0.82" is actionable, "blocked" is not.
```

- [ ] **Step 6: Prove the guards are falsifiable**

Two scratch (uncommitted) edits, each reverted after checking:

1. Delete the `elif [[ -n "$floor_failed" ]]` arm. The three floor-blocking tests must fail.
2. Change `select(($scores | length) > 0)` in the `floor_failed` query to `select(true)` — the "absent criterion_scores never block" test must fail, proving absence is genuinely excluded rather than accidentally passing.

**Report both results in your report file.**

- [ ] **Step 7: Verify the whole suite**

Run: `npm run test:ci`
Expected: exit 0, read from `$?` directly.

- [ ] **Step 8: Commit**

```bash
git add plugins/tribunal/scripts/lib/tribunal-gate.sh plugins/tribunal/skills/tribunal/SKILL.md test/bats/tribunal-gate.bats
git commit -m "feat(tribunal): let a criterion floor block a passing score :octagonal_sign:"
```

---

### Task 4: Librarian's aggregate and gate become rubric-aware

**Files:**
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-judge.sh:12-81` and `:164-169`
- Test: `test/bats/librarian-lesson-judge.bats`

**Interfaces:**
- Consumes: the `criterion_scores` contract from Task 1.
- Produces:
  - `librarian_lesson_aggregate <verdicts_json> [<rubric_json>]` — optional trailing rubric. With usable criterion scores it returns the weighted mean; otherwise the plain mean it returns today. Still returns 1 on an empty panel.
  - `librarian_lesson_gate <gate_policy> <verdicts_json> <aggregate> <threshold> [<rubric_json>]` — optional trailing rubric. Adds the reason `criterion_floor` with a `failed_criterion` key to its echoed JSON. Existing reasons (`gate_passed`, `below_threshold`, `jury_not_majority`, `jury_not_unanimous`, `unknown_gate_policy`) are unchanged.

Librarian's reasons are written to on-disk proposal JSON, **not** to a schema-validated event, so this costs no schema version.

**Duplication with Tasks 2 and 3 is deliberate** — see Global Constraints and `plugins/librarian/docs/adr/002-agent-definitions-are-shared-assets.md`.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-judge.bats`:

```bash
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

@test "a low generality score no longer blocks a public lesson" {
	# The behavioral difference from the unanimous stand-in. generality's floor
	# is 0.6; 0.65 clears it, so a judge merely unhappy about generality does
	# not veto a public lesson the way unanimous would have.
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: FAIL — the weighted and floor tests fail. The degrade, empty-panel, no-rubric, and precedence tests pass already, pinning behavior that must survive.

- [ ] **Step 3: Widen `librarian_lesson_aggregate`**

Replace `plugins/librarian/scripts/lib/librarian-lesson-judge.sh:17-29` with:

```bash
# Aggregate the judges' scores. Returns 1 on an empty panel.
#
# With a rubric and per-criterion scores, this is a weighted mean: average the
# judges on each criterion, weight each criterion's mean, normalize by the
# weights actually used. Without them it is the plain mean it has always been.
#
# A criterion no judge scored contributes nothing and its weight leaves the
# denominator — absence is not a zero. Scoring it 0 instead would turn a judge
# that skipped a criterion into one that failed it.
#
# Usage: librarian_lesson_aggregate <verdicts_json> [<rubric_json>]
librarian_lesson_aggregate() {
	local verdicts="${1:-[]}"
	local rubric="${2:-}"
	[ -z "$rubric" ] && rubric='{}'

	local n
	n=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || return 1
	[[ -z "$n" || "$n" -eq 0 ]] && return 1

	local weighted
	weighted=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
		. as $v
		| [ ($rubric.criteria // [])[]
		    | select((.name | type) == "string" and (.weight | type) == "number")
		    | . as $c
		    | ([ $v[]
		         | select((.criterion_scores | type) == "object")
		         | select(.criterion_scores | has($c.name))
		         | .criterion_scores[$c.name]
		         | select(type == "number") ]) as $scores
		    | select(($scores | length) > 0)
		    | { w: $c.weight, m: (($scores | add) / ($scores | length)) } ]
		| (map(.w) | add) as $den
		| if length == 0 or $den == null or $den <= 0 then empty
		  else (map(.w * .m) | add) / $den
		  end
	' 2>/dev/null)
	if [ -n "$weighted" ]; then
		printf '%s' "$weighted"
		return 0
	fi

	printf '%s' "$verdicts" | jq -r '[.[].score] | add / length' 2>/dev/null || return 1
}
```

- [ ] **Step 4: Widen `librarian_lesson_gate`**

Replace the doc comment and signature at `:31-41` with:

```bash
# Decide pass/block from the panel, the aggregate, and the rubric's floors.
#
# Echoes {"passed": bool, "reason": string} and, when a floor failed, a
# "failed_criterion" naming it. Three conditions must hold: the jury clears its
# policy, the aggregate clears the threshold, and no criterion sits below its
# min_pass.
#
# The floor is what makes the public tier meaningfully stricter than org. Before
# it existed, lesson-promotion-public declared gate_policy `unanimous` for that
# purpose and it did nothing at all — see ecosystem-j74.
#
# Usage: librarian_lesson_gate <gate_policy> <verdicts_json> <aggregate> <threshold> [<rubric_json>]
librarian_lesson_gate() {
	local policy="${1:-majority}"
	local verdicts="${2:-[]}"
	local aggregate="${3:-0}"
	local threshold="${4:-0.75}"
	local rubric="${5:-}"
	[ -z "$rubric" ] && rubric='{}'
```

Then replace the threshold check at `:74-80` with:

```bash
	# awk for the float comparison: bash cannot compare decimals.
	if ! awk -v s="$aggregate" -v t="$threshold" 'BEGIN { exit !(s >= t) }'; then
		printf '{"passed":false,"reason":"below_threshold"}'
		return 0
	fi

	# Per-criterion floors, checked last: the jury and the aggregate are both
	# more actionable to report, so they take precedence.
	local floor_failed
	floor_failed=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
		. as $v
		| [ ($rubric.criteria // [])[]
		    | select((.name | type) == "string" and (.min_pass | type) == "number")
		    | . as $c
		    | ([ $v[]
		         | select((.criterion_scores | type) == "object")
		         | select(.criterion_scores | has($c.name))
		         | .criterion_scores[$c.name]
		         | select(type == "number") ]) as $scores
		    | select(($scores | length) > 0)
		    | select((($scores | add) / ($scores | length)) < $c.min_pass)
		    | $c.name ]
		| first // empty
	' 2>/dev/null) || floor_failed=""

	if [[ -n "$floor_failed" ]]; then
		printf '{"passed":false,"reason":"criterion_floor","failed_criterion":"%s"}' "$floor_failed"
		return 0
	fi

	printf '{"passed":true,"reason":"gate_passed"}'
	return 0
}
```

- [ ] **Step 5: Thread the rubric through the caller**

In `librarian_lesson_judge`, replace lines 164-166 with:

```bash
		local aggregate gate
		aggregate=$(librarian_lesson_aggregate "$verdicts" "$rubric") || return 2
		gate=$(librarian_lesson_gate "$policy" "$verdicts" "$aggregate" "$threshold" "$rubric") || {
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: PASS, 55/55.

- [ ] **Step 7: Prove the guards are falsifiable**

Three scratch (uncommitted) edits, each reverted after checking:

1. Delete the `if [[ -n "$floor_failed" ]]` block. The disclosure-floor tests must fail.
2. Change `.criterion_scores[$c.name]` to `(.criterion_scores[$c.name] // 0)` and drop the `has()` select. **`scores present but one floored criterion omitted` must fail, while `a criterion scored zero does block` still passes** — that pair is what discriminates absence from zero.

   **Do not expect `a verdict with no criterion_scores key at all` to fail here.** It will not, and that is correct: its fixture is removed by the outer `select((.criterion_scores | type) == "object")` before the `has()` lookup is ever reached. Task 3 shipped with only that weaker test and the guard was consequently unpinned — verified, not hypothetical. If you find yourself editing the no-key test to make it fail, stop: you would be deleting the coverage of the pre-upgrade case to duplicate a test you already have.
3. Revert Step 5's rubric threading (pass no rubric from `librarian_lesson_judge`). Any end-to-end judging test that exercises a floor must fail. **If none does, that is a coverage gap — add one before finishing.**

**Report all three results in your report file.**

- [ ] **Step 8: Verify the whole suite**

Run: `npm run test:ci`
Expected: exit 0, read from `$?` directly.

- [ ] **Step 9: Commit**

```bash
git add plugins/librarian/scripts/lib/librarian-lesson-judge.sh test/bats/librarian-lesson-judge.bats
git commit -m "feat(librarian): weight and floor the lesson jury's criteria :straight_ruler:"
```

---

### Task 5: The public tier gets a real floor

**Files:**
- Modify: `plugins/librarian/config.json` (`.librarian.lesson_judging.rubrics[1].gate_policy`)
- Modify: `plugins/librarian/scripts/lib/librarian-lesson-rubric.sh:9-13`
- Modify: `plugins/librarian/skills/librarian/SKILL.md:106-114`
- Modify: `docs/superpowers/specs/2026-08-11-lesson-judging-design.md`
- Modify: `docs/superpowers/specs/2026-08-14-criterion-scores-design.md`
- Test: `test/bats/librarian-lesson-judge.bats`

**Interfaces:**
- Consumes: `librarian_lesson_gate`'s rubric parameter and `criterion_floor` reason from Task 4.
- Produces: nothing later tasks depend on. This is the terminal task.

Closes `ecosystem-j74`.

- [ ] **Step 1: Write the failing tests**

Append to `test/bats/librarian-lesson-judge.bats`:

```bash
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

@test "the librarian walk tells judges to return criterion_scores" {
	# The rubric floors are unreachable unless the judges actually score them,
	# and this walk is where librarian's judges get their instructions.
	grep -q 'criterion_scores' "${REPO_ROOT}/plugins/librarian/skills/librarian/SKILL.md"
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: FAIL — the gate-policy test and the SKILL.md test fail. The floor and criteria-differ tests pass already, pinning what must not regress.

- [ ] **Step 3: Swap the public tier's gate policy**

In `plugins/librarian/config.json`, in the rubric with `"id": "lesson-promotion-public"`, change:

```json
"gate_policy": "unanimous",
```

to:

```json
"gate_policy": "majority",
```

Leave every criterion, weight, floor and `score_threshold` exactly as they are.

- [ ] **Step 4: Correct the rubric library's comment**

Replace `plugins/librarian/scripts/lib/librarian-lesson-rubric.sh:9-13` — which claims the weights are inert — with:

```bash
# The per-criterion weights and min_pass floors are LIVE as of ecosystem-pht:
# librarian_lesson_aggregate weights them and librarian_lesson_gate blocks on
# any criterion below its floor.
#
# `disclosure` at min_pass 0.9 is what makes the public tier stricter than org.
# It replaces gate_policy `unanimous`, which was intended as a stand-in for
# exactly this and turned out to be a no-op: at the configured two-judge panel,
# `unanimous` and `majority` agree on every possible pass count. See
# ecosystem-j74. Changing judge_types without re-reading that bead is how the
# hole reopens.
```

- [ ] **Step 5: Tell librarian's judges to score the criteria**

In `plugins/librarian/skills/librarian/SKILL.md`, replace the bullet at lines 112-114 with:

```markdown
   - Each judge returns a JSON object with `score`, `passed`, `judge_type`,
     `feedback_summary`, and `criterion_scores` — a map from **each rubric
     criterion name you gave it** to a score in `[0,1]`. Tell each judge
     explicitly to omit any criterion it cannot assess rather than scoring it
     `0`: a `0` on `disclosure` blocks a public lesson by itself, while an
     omission does not. Collect both verdicts into a JSON array **verbatim** —
     never summarize or reconstruct a judge's verdict.
```

- [ ] **Step 6: Correct the 4z8.3 spec**

In `docs/superpowers/specs/2026-08-11-lesson-judging-design.md`, find the passage describing `gate_policy: unanimous` as the public tier's protection and replace its claim with:

```markdown
**Correction (2026-08-14).** This section described `unanimous` as delivering
"a single judge's objection cannot be outvoted." It never did. Both rubrics
declare `judge_types: ["standard", "adversarial"]` — a panel of two — and at
panel size two `unanimous` (`passed == count`) and `majority`
(`passed * 2 > count`) return the same answer for all three possible pass
counts. They diverge only at three judges or more, and `librarian_lesson_judge`
refuses any panel whose judge-type multiset does not match the rubric's, so a
third judge never reaches the gate.

The public tier was never stricter than the org tier. `ecosystem-pht` replaced
the stand-in with `disclosure`'s real `min_pass` floor and the policy is now
`majority`. Tracked as `ecosystem-j74`.
```

- [ ] **Step 7: Correct the criterion-scores spec**

In `docs/superpowers/specs/2026-08-14-criterion-scores-design.md`, the "Judges emit it" section says `tribunal-judge-standard` and `-security` already receive the rubric. Only `-standard` does. Replace that sentence with:

```markdown
`tribunal-judge-standard` already receives the rubric with its criteria and is
told to "score each criterion in [0,1]". It has nowhere to put the result; its
output contract gains `criterion_scores`.

**Neither `tribunal-judge-adversarial` nor `tribunal-judge-security` has a
rubric section at all.** Both report `criteria_evaluated` lists drawn from their
own investigative lenses — `edge-cases`, `concurrency`, `idempotency` for one;
`injection`, `secrets`, `path-traversal` for the other — disjoint from every
rubric in the repo.
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `bats test/bats/librarian-lesson-judge.bats`
Expected: PASS, 59/59.

- [ ] **Step 9: Prove the swap actually changed behavior**

The gate-policy test only reads config. Confirm the swap changes an outcome: temporarily set `gate_policy` back to `unanimous` in a scratch edit and re-run the two public-tier gate tests from Task 4. **They must still pass** — because at panel 2 the policies are identical, which is the whole finding. Record that result in your report file as direct evidence that the floor, not the policy, is doing the work now.

- [ ] **Step 10: Verify the whole suite**

Run: `npm run test:ci`
Expected: exit 0, read from `$?` directly.

- [ ] **Step 11: Commit**

```bash
git add plugins/librarian/config.json plugins/librarian/scripts/lib/librarian-lesson-rubric.sh plugins/librarian/skills/librarian/SKILL.md docs/superpowers/specs/2026-08-11-lesson-judging-design.md docs/superpowers/specs/2026-08-14-criterion-scores-design.md test/bats/librarian-lesson-judge.bats
git commit -m "feat(librarian): give the public tier a floor that actually holds :closed_lock_with_key:"
```

---

## After the tasks

- Close `ecosystem-pht` and `ecosystem-j74`.
- Open a PR into `main` per the repo's PR-only rule. The PR body should lead with the j74 finding — a reviewer who does not know the `unanimous` stand-in was inert will read the `majority` swap as a loosening rather than a tightening.
- Not in scope, deliberately: retiring `criteria_evaluated`; any new judge type; widening `judge_types` to three (rejected — it buys a property this plan delivers anyway, at the cost of a third Opus judge per public candidate); and the `TODO(ONL-6)` hard-fail on type/schema divergence, which is the schema repo's own cleanup.

## Self-review

**Spec coverage.** Payload consumption → Tasks 2, 3, 4. Judges emit it → Task 1. `weighted_mean` real → Task 2. Normalize by weight sum → Tasks 2 and 4. Degrade to mean → Tasks 2 and 4. `min_pass` enforceable → Tasks 3 and 4. Absent must not block → Tasks 3 and 4. Public tier's real floor → Task 5. Doc corrections → Task 5. Dependency bump → Task 1. Every test the spec calls for maps to a step, including the two it gained in correction (hyphenated names, unscored floors).

**One gap the spec left open, resolved here:** it never said whether judges score *rubric* criteria or their own lenses. They score rubric criteria; `criteria_evaluated` keeps its present meaning. Without that decision `criterion_scores` keys would never match a floor.

**Type consistency.** `criterion_scores` is an object of name → number everywhere. `failed_criterion` is a string, present only alongside `reason: "criterion_floor"`, in both plugins. Both new parameters are optional and trailing: `tribunal_aggregate` position 3 (existing, now used), `tribunal_gate_decide` position 8 (new), `librarian_lesson_aggregate` position 2 (new), `librarian_lesson_gate` position 5 (new).

**Precedence differs between the plugins, deliberately.** Tribunal: `low_score` → `criterion_floor` → jury reasons. Librarian: jury → `below_threshold` → `criterion_floor`. Each preserves its own existing order and appends the floor where that order allows; unifying them would change shipped behavior in one of the two.

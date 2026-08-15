# Per-Criterion Scores — Schema Half Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional `criterion_scores` map to `TribunalVerdictPayload` so per-criterion scores can be emitted at all.

**Architecture:** One field, in two files that must move together — the JSON Schema is the runtime contract, `src/types.ts` is hand-written and only cross-checked. Plus tests and a conventional commit that release-please turns into a version.

**Tech Stack:** JSON Schema (draft 2020-12), TypeScript, vitest, release-please.

## ⚠️ This plan runs in a DIFFERENT repository

**Every implementation step below operates in `~/src/github.com/onlooker-community/schema`**, currently `main` at `46a79b4`, version `2.11.0`. That is the package the ecosystem depends on (`^2.11.0`).

This plan file lives in the ecosystem repo only because that is where the spec and the tracking bead (`ecosystem-pht`) live. **Do not edit ecosystem files.** The ecosystem half — judges emitting the field, real `weighted_mean`, `min_pass` enforcement, and librarian's disclosure floor — is a separate plan that starts only after this version publishes.

## Global Constraints

- **The field is optional.** It must NOT appear in the payload's `required` array. Three shipped plugins emit this payload and the runtime emitter validates whenever the package resolves; requiring it would invalidate every existing producer the moment the version bumps.
- **The field is a map, not a parallel array.** `{"type": "object", "additionalProperties": {"type": "number", "minimum": 0, "maximum": 1}}`. An array beside `criteria_evaluated` would have to stay index-aligned with nothing enforcing it, and a silent misalignment attributes each score to the wrong criterion — worse than having no scores.
- **`additionalProperties` for the values, not enumerated criterion names.** Criterion names come from user-extensible rubrics (ADR-004). Librarian's `lesson-promotion` rubric uses `grounding`, `scope_accuracy`, `generality`, `disclosure` — none of which appear in tribunal's default rubric. Enumerating keys would make every new rubric a schema change.
- **`criteria_evaluated` and `criterion_scores` are deliberately allowed to disagree.** A judge may evaluate a criterion it cannot score. Cross-field consistency belongs at ingest, mirroring the lesson contract's reasoning for leaving `agreed <= judges` out of `ZConsensus`. Do not add a constraint tying them together.
- **Both files change in step.** `src/types.ts` is hand-written; `schemas/payload/plugins-safety.json` is the runtime contract. `scripts/generate-types.js` cross-checks them but its own header says divergence is a warning, not a hard failure (`TODO(ONL-6 hard fail)`). **Nothing will catch a drift** — that is why this is one task, not two.
- **Do not hand-edit a version.** Release is via release-please; ship a conventional commit and the release PR follows.
- American English. Commit per the `/commit` contract: `<type>(<scope>): <subject> :emoji:`, subject ≤72 chars including the emoji, why-focused body.

## Context that shapes the work

The verdict payload already sets **`"additionalProperties": false`** (verified: `$defs/tribunal.verdict`, `required: ["task_id","score","passed","judge_type"]`). So today a producer emitting `criterion_scores` is **rejected outright** — which is precisely why the schema must land before any consumer can emit it, and why this addition is strictly safe: adding the property permits it, and its absence from `required` keeps every current producer valid.

## File Structure

| File | Responsibility |
|---|---|
| `schemas/payload/plugins-safety.json` | **Modify.** The runtime contract — add the property to `$defs/tribunal.verdict`. |
| `src/types.ts` | **Modify.** The hand-written type at `TribunalVerdictPayload` (line 218). |
| `src/validate.test.ts` | **Modify.** Fixture-based vitest cases. |

---

### Task 1: Add `criterion_scores` to the verdict payload

**Files (all in `~/src/github.com/onlooker-community/schema`):**
- Modify: `schemas/payload/plugins-safety.json` — `$defs/tribunal.verdict`, after `criteria_evaluated` (~line 180)
- Modify: `src/types.ts:218` — `TribunalVerdictPayload`
- Test: `src/validate.test.ts`

**Interfaces:**
- Produces: `criterion_scores?: Record<string, number>` on `TribunalVerdictPayload`, and the matching JSON Schema property. The ecosystem half consumes both.

- [ ] **Step 1: Create a branch**

```bash
cd ~/src/github.com/onlooker-community/schema
git switch -c feat/criterion-scores
```

- [ ] **Step 2: Write the failing tests**

Add these to `src/validate.test.ts`, inside the existing tribunal `describe` block that defines the `tribunal()` helper (around line 348) and the `TASK_ID` / `ITERATION_ID` constants. The helper's signature is `tribunal<T extends EventType>(event_type, payload)`.

Match the file's existing assertion style: `expect(result.valid).toBe(false)` followed by an `if (!result.valid)` guard before touching `result.errors`.

```ts
	it("accepts a verdict carrying per-criterion scores", () => {
		const result = validate(
			tribunal(TRIBUNAL_VERDICT, {
				task_id: TASK_ID,
				score: 0.85,
				passed: true,
				judge_type: "standard",
				criterion_scores: { correctness: 0.9, safety: 0.8 },
			}),
		);
		expect(result.valid).toBe(true);
	});

	it("accepts a verdict with no criterion_scores at all", () => {
		// Every producer today omits it. Making the field required would
		// invalidate all three shipped plugins on the version bump.
		const result = validate(
			tribunal(TRIBUNAL_VERDICT, {
				task_id: TASK_ID,
				score: 0.85,
				passed: true,
				judge_type: "standard",
			}),
		);
		expect(result.valid).toBe(true);
	});

	it("accepts an arbitrary criterion name", () => {
		// The point of the map: criterion names come from user-extensible
		// rubrics, so they cannot be enumerated in the schema. These four are
		// librarian's lesson-promotion rubric, none of which tribunal's own
		// default rubric uses.
		const result = validate(
			tribunal(TRIBUNAL_VERDICT, {
				task_id: TASK_ID,
				score: 0.85,
				passed: true,
				judge_type: "standard",
				criterion_scores: {
					grounding: 0.9,
					scope_accuracy: 0.8,
					generality: 0.7,
					disclosure: 0.95,
				},
			}),
		);
		expect(result.valid).toBe(true);
	});

	it("rejects a criterion score above 1", () => {
		const result = validate(
			tribunal(TRIBUNAL_VERDICT, {
				task_id: TASK_ID,
				score: 0.85,
				passed: true,
				judge_type: "standard",
				criterion_scores: { correctness: 1.5 },
			}),
		);
		expect(result.valid).toBe(false);
		if (!result.valid) {
			expect(
				result.errors.some((e) => e.path.includes("criterion_scores")),
			).toBe(true);
		}
	});

	it("rejects a criterion score below 0", () => {
		const result = validate(
			tribunal(TRIBUNAL_VERDICT, {
				task_id: TASK_ID,
				score: 0.85,
				passed: true,
				judge_type: "standard",
				criterion_scores: { correctness: -0.1 },
			}),
		);
		expect(result.valid).toBe(false);
	});

	it("rejects a non-number criterion score", () => {
		const result = validate(
			tribunal(TRIBUNAL_VERDICT, {
				task_id: TASK_ID,
				score: 0.85,
				passed: true,
				judge_type: "standard",
				criterion_scores: { correctness: "high" },
			} as unknown as Parameters<typeof tribunal>[1]),
		);
		expect(result.valid).toBe(false);
	});

	it("allows criteria_evaluated and criterion_scores to disagree", () => {
		// Deliberate: a judge may evaluate a criterion it cannot score.
		// Cross-field consistency belongs at ingest, not in a JSON Schema —
		// the same reasoning that keeps `agreed <= judges` out of ZConsensus
		// in the lesson contract.
		const result = validate(
			tribunal(TRIBUNAL_VERDICT, {
				task_id: TASK_ID,
				score: 0.85,
				passed: true,
				judge_type: "standard",
				criteria_evaluated: ["correctness", "safety", "clarity"],
				criterion_scores: { correctness: 0.9 },
			}),
		);
		expect(result.valid).toBe(true);
	});
```

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd ~/src/github.com/onlooker-community/schema
npm test 2>&1 | tail -20
```

Expected: the three "accepts" tests that pass `criterion_scores` **FAIL**, because the payload sets `"additionalProperties": false` and the property does not exist yet. "accepts a verdict with no criterion_scores at all" passes already — that is correct, it is the regression guard for existing producers. The three "rejects" tests may pass for the *wrong* reason right now (rejected as an unknown property rather than for their range or type), which is exactly why Step 6 re-checks them.

- [ ] **Step 4: Add the property to the JSON Schema**

In `schemas/payload/plugins-safety.json`, inside `$defs/tribunal.verdict`'s `properties`, immediately after the `criteria_evaluated` block:

```json
				"criterion_scores": {
					"type": "object",
					"additionalProperties": { "type": "number", "minimum": 0, "maximum": 1 },
					"description": "Per-criterion score keyed by criterion name, in [0,1]. Criterion names come from the active rubric and are not enumerable here. May disagree with criteria_evaluated: a judge can evaluate a criterion it cannot score. Consistency between the two is an ingest concern."
				},
```

**Do not add it to `required`.** Leave the payload's `additionalProperties: false` as it is — that is what makes the field a contract rather than a convention.

- [ ] **Step 5: Add the matching field to the hand-written type**

In `src/types.ts`, in `TribunalVerdictPayload` (line 218), after `criteria_evaluated?: string[];`:

```ts
	criterion_scores?: Record<string, number>;
```

This file is hand-written and only cross-checked by `scripts/generate-types.js`, whose header says divergence is a warning rather than a hard failure. If this step is skipped the JSON Schema and the type silently disagree, and TypeScript consumers cannot set the field even though the runtime accepts it.

- [ ] **Step 6: Run the tests to verify they pass — and for the right reason**

```bash
cd ~/src/github.com/onlooker-community/schema
npm test 2>&1 | tail -20
```

Expected: all pass.

Then confirm the three "rejects" tests now fail for their *own* reason rather than as unknown properties. In a scratch copy of the schema (not committed), temporarily widen the value constraint to `{"type": "number"}` — dropping `minimum`/`maximum` — and re-run: "rejects a criterion score above 1" and "below 0" must now **fail**, while "rejects a non-number criterion score" still passes. Restore the constraint.

**If they still pass with the range removed, they are not testing the range** — say so plainly in your report rather than treating them as proven.

- [ ] **Step 7: Run the full checks**

```bash
cd ~/src/github.com/onlooker-community/schema
npm run validate-schemas; echo "validate-schemas: $?"
npm run typecheck;        echo "typecheck: $?"
npm run ci;               echo "ci (biome): $?"
npm run build;            echo "build: $?"
npm run test;             echo "test: $?"
```

Read each exit code directly — **never through a pipe**, which reports the pipe's last command.

`npm run build` runs `generate-types` and may print a divergence warning; read it. If it reports a mismatch on `criterion_scores`, the JSON Schema and `src/types.ts` disagree and one of Steps 4–5 is wrong.

- [ ] **Step 8: Commit**

```bash
cd ~/src/github.com/onlooker-community/schema
git add schemas/payload/plugins-safety.json src/types.ts src/validate.test.ts
```

Commit subject: `feat(tribunal): carry per-criterion scores on a verdict :straight_ruler:`

The body should say why the field is optional (three shipped producers, and the emitter validates whenever the package resolves) and why it is a map rather than a parallel array (index alignment has nothing enforcing it). `feat` matters: release-please cuts a minor version from it, which is what the ecosystem half will depend on.

- [ ] **Step 9: Push and open a PR**

```bash
cd ~/src/github.com/onlooker-community/schema
git push -u origin feat/criterion-scores
```

Open the PR against `main`. Note in its body that this is the first half of `ecosystem-pht` and that no consumer changes ship until the release lands.

---

## Spec coverage

| Spec requirement | Step |
|---|---|
| Optional, absent from `required` | 4 |
| Map with `additionalProperties` values in `[0,1]` | 4 |
| Criterion names not enumerated | 4, and pinned by the arbitrary-name test in 2 |
| `criteria_evaluated` may disagree | 4 (no cross-field constraint) and pinned in 2 |
| Both files edited in step | 4, 5, and the divergence check in 7 |
| A verdict with scores validates | 2 |
| A score outside `[0,1]` does not | 2, re-checked in 6 |
| A non-number value does not | 2, re-checked in 6 |
| Omitting the field still validates | 2 |
| Released via release-please, not a hand-edited version | 8 |

## Out of scope

Retiring `criteria_evaluated`. Any judge-agent change, `weighted_mean`, `min_pass` enforcement, or librarian's disclosure floor — all the ecosystem half, which starts after this publishes. And the `TODO(ONL-6)` hard-fail on type/schema divergence, which is the schema repo's own cleanup.

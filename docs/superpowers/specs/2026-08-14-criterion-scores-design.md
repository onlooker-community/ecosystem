# Per-Criterion Scores — Design

**Status:** Approved, not started.
**Tracked by:** `ecosystem-pht`.
**Spans two repositories.** The payload lives in `@onlooker-community/schema`;
the consumers live here.

---

## What this is

Tribunal's rubrics declare a `weight` and a `min_pass` per criterion, and
`tribunal-rubric.sh` validates both are numbers in `[0,1]`. **Neither is ever
applied.**

`tribunal_aggregate` takes the rubric as its third parameter and explicitly
discards it (`: "$_rubric"`); `weighted_mean` falls through to the same jq
expression as `mean`, a plain average of each judge's single overall score.
`min_pass` is enforced nowhere at all, because `TribunalVerdictPayload` carries
one scalar `score`, one boolean `passed`, and `criteria_evaluated` — a list of
criterion *names* with no scores attached. The orchestrator never learns what a
judge scored on any individual criterion.

So a rubric cannot express "this one criterion is a floor." A judge scoring 0.3
on a safety-critical criterion and 0.95 on everything else can still report
`passed: true`, and under `gate_policy: majority` a single dissenter is
outvoted regardless.

## Why it matters now

`ecosystem-4z8.3` shipped a public tier for lesson promotion whose entire
safety argument was a disclosure floor at `min_pass` 0.9 — a near-veto, on the
reasoning that correctness rots and `applies_to` retires it, but harm does not:
a leaked credential never expires on its own.

That floor could not be built, so the public tier ships `gate_policy:
unanimous` instead — a deliberate stand-in intended to deliver the property
that mattered ("a single judge's objection cannot be outvoted"), though not
disclosure-specific.

**The stand-in does not work.** Both librarian rubrics declare `judge_types:
["standard", "adversarial"]`, a panel of two, and at panel size two
`unanimous` (`passed == count`) and `majority` (`passed * 2 > count`) return
the same answer for every possible pass count — 0, 1, or 2. They diverge only
at three judges or more, and `librarian_lesson_judge`'s `usable` check refuses
any panel whose judge-type multiset does not exactly match the rubric's, so a
third judge never reaches the gate. **The public tier has never been stricter
than the org tier.**

Two individually-correct changes combined to produce an inert one. Tracked as
`ecosystem-j74`.

That makes this design load-bearing rather than an improvement: the public
tier has no extra protection today, and the floor below is what gives it one.
The `4z8.3` spec and the `lesson-promotion-public` rubric comment both still
describe `unanimous` as a working guarantee and must be corrected.

## The payload

Add `criterion_scores` to `TribunalVerdictPayload`, alongside the existing
`criteria_evaluated`:

```jsonc
"criterion_scores": {
  "type": "object",
  "additionalProperties": { "type": "number", "minimum": 0, "maximum": 1 }
}
```

### Optional, not required

Three shipped plugins emit this payload, and the runtime emitter validates
whenever the schema package is resolvable. Making the field required would
invalidate every existing producer the moment the version bumps.

Optional also matches reality during the rollout: the ecosystem consumes the
new version before its judge agents emit the field, so consumers must handle
absence anyway.

### A map, not a parallel array

`criteria_evaluated` is already a name list. A scores array beside it would
have to stay index-aligned, with nothing enforcing that — and a
silently-misaligned pair attributes each score to the wrong criterion, which is
worse than having no scores.

A map makes the association explicit and lets the aggregator look up by the
rubric's own criterion name.

### `additionalProperties`, not fixed keys

Criterion names come from a rubric, and rubrics are user-extensible per
ADR-004. Librarian's `lesson-promotion` already defines `grounding`,
`scope_accuracy`, `generality`, and `disclosure` — none of which appear in
tribunal's default rubric. Enumerating keys in the schema would make every new
rubric a schema change.

### `criteria_evaluated` and `criterion_scores` may disagree

Deliberately not constrained. A judge may evaluate a criterion it cannot score,
or score one it did not list. Cross-field consistency belongs at ingest, not in
a JSON Schema — the same reasoning the lesson contract gives for leaving
`agreed <= judges` out of `ZConsensus`.

### The block needs a reason of its own

`tribunal.gate.blocked` carries a closed `reason` enum — `low_score`,
`meta_override`, `bias_detected`, `dissent_unresolved` — under
`additionalProperties: false`. None of them describes a criterion floor, and
the whole premise of the floor is a block that fires *while the aggregate
clears `score_threshold`*. Emitting `low_score` would be false, and
indistinguishable from a genuine threshold miss.

So the same release adds `criterion_floor` to the enum plus an optional
`failed_criterion` string. It ships here rather than with the consumers
because the event log is append-only: every floor block emitted before the
enum existed would be permanently recorded as a low-score block.

Librarian's own gate needs no schema change for this — its verdict reason is
written to on-disk proposal JSON, not to a schema-validated event.

### Both files change together

`src/types.ts` is **hand-written**; `schemas/payload/plugins-safety.json` is the
runtime contract. `scripts/generate-types.js` cross-checks them, but its own
header says divergence is currently a warning rather than a hard failure
(`TODO(ONL-6 hard fail)`). Nothing will stop the two from drifting, so they must
be edited in step and the test fixture must exercise the new field.

## The consumers

Second PR, after the schema version publishes.

### Judges emit it

`tribunal-judge-standard` and `-security` already receive the rubric with its
criteria and are told to "score each criterion in [0,1]". They have nowhere to
put the result; their output contract gains `criterion_scores`.

**`tribunal-judge-adversarial` has no rubric section at all.** Its output keys
— edge cases, concurrency, idempotency — are disjoint from every rubric in the
repo. On tribunal's default panel that means `safety`, the criterion carrying
the *highest* floor at `min_pass: 0.8`, would be scored by zero judges; under
"absent scores must not block," its floor would silently never fire. The
design's own failure mode, reappearing one layer down and looking like it
works.

So the adversarial agent needs a rubric section before any floor can be
trusted, and the consumer plan must state which judge types are expected to
score which criteria. A floor on a criterion no judge scores is not a floor.

### `weighted_mean` becomes real

`tribunal_aggregate` already receives the rubric it discards. Weight each
criterion, then average judges per criterion.

**Normalize by the sum of weights rather than assuming 1.0.** Tribunal's own
`tribunal-rubric.sh` does validate the total, rejecting any rubric outside
0.99–1.01 — so a mis-summed rubric cannot reach the aggregator through *that*
path. But librarian does not use it: `librarian_lesson_rubric_get` performs no
validation at all, and a librarian rubric summing to 1.30 would silently
mis-score. Normalizing costs one division and removes the difference between
the two paths.

**Degrade to `mean` when scores are absent**, which is the state of every
verdict emitted before the judges are updated. Silently producing 0 for a
missing criterion would turn an un-upgraded judge into a blocking one.

**Absent must stay distinguishable from zero, in the code as well as the
contract.** `jq`'s `// 0` idiom is reflexive throughout these libraries and
collapses exactly that distinction — a judge that did not score a criterion
would read as a judge that scored it 0.0, the failure mode this whole section
exists to avoid. Use `has()` or an explicit `null` test.

**Look criterion names up with `--arg`, never on a dotted path.** Hyphenated
names are already in shipped agent contracts (`path-traversal`, `edge-cases`),
and `jq '.criterion_scores.path-traversal'` is a *compile* error — `jq` exits 3
with empty stdout, which `awk` then reads as 0. That fails toward blocking, on
a name the rubric author is entitled to write. `.criterion_scores[$name]` with
`--arg name` is correct for every name.

### Librarian needs signature changes the bead did not budget for

Librarian does not call either tribunal function named above. Its
`librarian_lesson_aggregate` takes **no rubric parameter** and hardcodes a
plain mean; `librarian_lesson_gate` receives no criteria either. Both need
their signatures widened before the public tier's floor can exist, and the
consumer plan must schedule that work rather than assuming tribunal's
aggregator is shared.

### `min_pass` becomes enforceable

`tribunal_gate_decide` blocks when any criterion scores below its floor,
regardless of the aggregate or the gate policy. That is the whole point: a
floor a strong weighted mean cannot average away.

**Absent scores must not block.** A verdict with no `criterion_scores` cannot
violate a floor it never reported, and treating absence as violation would make
every pre-upgrade judge fail every rubric with a floor.

### The public tier gets its real floor

Librarian's `lesson-promotion-public` swaps `gate_policy: unanimous` back to
`majority`, relying on `disclosure`'s `min_pass: 0.9` to do the blocking.

This is the point where the public tier first becomes stricter than the org
tier in fact rather than in intent — see `ecosystem-j74`. The swap is
therefore not a simplification, and the decision was to let this work supply
the protection rather than widen the panel now and pay for a third Opus judge
on every public candidate.

The `4z8.3` spec records `unanimous` as an explicit stand-in and says "when
`pht` lands, this can narrow to a true per-criterion floor." That spec, and the
librarian rubric comment describing the weights as inert, both need updating —
and the correction is not only that the stand-in was replaced, but that it
never had the effect it claimed.

## Testing

Schema repo: the existing fixture-based `validate.test.ts`. A verdict carrying
`criterion_scores` validates; one carrying a score outside `[0,1]` or a non-number
value does not; one omitting the field entirely still validates, because that is
every producer today. A gate.blocked with `reason: "criterion_floor"` validates
with and without `failed_criterion`; an unrecognized reason is still rejected,
and that test must fail because of the enum rather than
`additionalProperties`.

Ecosystem: bats, isolated temp home.

- **`weighted_mean` produces a different result from `mean` when weights are
  unequal.** Today they are identical, so any test that cannot tell them apart
  proves nothing.
- Weights summing to something other than 1.0 normalize correctly — driven
  through **librarian's** rubric loader, since tribunal's own validator rejects
  such a rubric before the aggregator ever sees it.
- A criterion below its `min_pass` blocks even when the aggregate clears
  `score_threshold` **and** the gate policy is satisfied — the property that
  does not exist today.
- A verdict with no `criterion_scores` neither blocks nor scores 0; aggregation
  degrades to `mean`. Distinctly: a verdict scoring a criterion **at** 0.0
  *does* block, proving absence and zero are not conflated.
- A hyphenated criterion name scores and gates correctly.
- A rubric whose floor names a criterion **no judge scored** is surfaced rather
  than silently passing — the adversarial-judge gap above, made visible.
- The public rubric, after the swap, blocks a lesson on a low `disclosure` score
  while a low `generality` score no longer blocks it. Note this is a difference
  from *intended* `unanimous` behavior, not from shipped behavior: at the
  configured panel of two, `unanimous` and `majority` are the same gate, so
  today's public tier blocks on neither.

## Out of scope

Retiring `criteria_evaluated`, which stays as-is. Any new judge type. The
`aggregation_method` enum, which already carries `weighted_mean`. And the
`TODO(ONL-6)` hard-fail on type/schema divergence — worth doing, but it is the
schema repo's own cleanup, not this thread's.

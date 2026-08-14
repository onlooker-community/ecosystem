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
unanimous` instead — a deliberate stand-in that delivers the property that
mattered ("a single judge's objection cannot be outvoted") but is not
disclosure-specific. A judge unhappy about `generality` also blocks a public
lesson.

**This design closes that loop**, and the second half below flips the public
rubric to a real floor once the mechanism exists.

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

### Both files change together

`src/types.ts` is **hand-written**; `schemas/payload/plugins-safety.json` is the
runtime contract. `scripts/generate-types.js` cross-checks them, but its own
header says divergence is currently a warning rather than a hard failure
(`TODO(ONL-6 hard fail)`). Nothing will stop the two from drifting, so they must
be edited in step and the test fixture must exercise the new field.

## The consumers

Second PR, after the schema version publishes.

### Judges emit it

The three shipped agents — `tribunal-judge-standard`, `-adversarial`,
`-security` — already receive the rubric with its criteria and are told to
"score each criterion in [0,1]". They just have nowhere to put the result.
Their output contract gains `criterion_scores`.

### `weighted_mean` becomes real

`tribunal_aggregate` already receives the rubric it discards. Weight each
criterion, then average judges per criterion.

**Normalize by the sum of weights rather than assuming 1.0.** `tribunal-rubric.sh`
validates each weight in `[0,1]` but never checks their total. Librarian's two
rubrics happen to sum to 1.00 because that was designed in deliberately; nothing
enforces it, and a rubric summing to 1.30 would silently mis-score.

**Degrade to `mean` when scores are absent**, which is the state of every
verdict emitted before the judges are updated. Silently producing 0 for a
missing criterion would turn an un-upgraded judge into a blocking one.

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

The `4z8.3` spec records `unanimous` as an explicit stand-in and says "when
`pht` lands, this can narrow to a true per-criterion floor." That spec, and the
librarian rubric comment describing the weights as inert, both need updating —
leaving them would leave the codebase describing a workaround it no longer uses.

## Testing

Schema repo: the existing fixture-based `validate.test.ts`. A verdict carrying
`criterion_scores` validates; one carrying a score outside `[0,1]` or a non-number
value does not; one omitting the field entirely still validates, because that is
every producer today.

Ecosystem: bats, isolated temp home.

- **`weighted_mean` produces a different result from `mean` when weights are
  unequal.** Today they are identical, so any test that cannot tell them apart
  proves nothing.
- Weights summing to something other than 1.0 normalize correctly.
- A criterion below its `min_pass` blocks even when the aggregate clears
  `score_threshold` **and** the gate policy is satisfied — the property that
  does not exist today.
- A verdict with no `criterion_scores` neither blocks nor scores 0; aggregation
  degrades to `mean`.
- The public rubric, after the swap, blocks a lesson on a low `disclosure` score
  while a low `generality` score no longer blocks it — the behavioral difference
  from the `unanimous` stand-in, and the reason this work exists.

## Out of scope

Retiring `criteria_evaluated`, which stays as-is. Any new judge type. The
`aggregation_method` enum, which already carries `weighted_mean`. And the
`TODO(ONL-6)` hard-fail on type/schema divergence — worth doing, but it is the
schema repo's own cleanup, not this thread's.

# ADR-002: Majority Gate Policy as Default

**Status:** Accepted  
**Date:** 2026-05-24

## Context

After the Jury and Meta-Judge tiers produce scores, the Gate must decide: accept the output, retry, or exhaust? Several policies were considered:

- **Score threshold only** — pass if `aggregated_score >= threshold` (e.g., 0.75).
- **Unanimous** — pass only if every judge voted passed.
- **Majority** — pass if strictly more than half of judges voted passed.
- **Meta-override** — the Meta-Judge's recommendation overrides the jury.
- **Hybrid** — any combination of the above.

The available policies in config are: `majority`, `strict` (alias for `unanimous`), `unanimous`, `meta_override`.

## Decision

The default gate policy is **`majority`**. The gate requires **both** the jury policy vote **and** `score_threshold` to clear — both conditions must be true for a pass. `score_threshold: 0.75` is a hard blocking condition, not just a reporting signal.

## Rationale

**Majority is the most intuitive policy for a multi-judge panel.** In any jury system, majority verdict is the natural baseline. It prevents a single outlier judge from blocking a good result indefinitely (the adversarial judge is *designed* to find fault and rarely gives a full pass).

**Unanimous is too strict for the default judge composition.** With `["standard", "adversarial"]`, the adversarial judge is built to be skeptical. A policy requiring it to pass alongside the standard judge effectively gives veto power to the judge whose job is to reject. In practice, unanimous with this composition would mean the gate almost never passes.

**Score threshold alone conflates jury agreement with quality.** A score of 0.8 from two judges who disagree strongly (e.g., 1.0 and 0.6) is a different signal than 0.8 from two judges who both scored 0.8. The majority policy captures agreement; the dissent threshold captures disagreement.

## The 2-judge edge case

The majority formula is `passed_count * 2 > total_count`. With two judges:

| Judges passed | Formula | Result |
|--------------|---------|--------|
| 2/2 | `2 * 2 > 2` → `4 > 2` | ✓ pass |
| 1/2 | `1 * 2 > 2` → `2 > 2` | ✗ block |
| 0/2 | `0 * 2 > 2` → `0 > 2` | ✗ block |

This means with the default two-judge panel, **both judges must pass** for the gate to open. This behaves like unanimous in the 2-judge case. This was observed during early Tribunal development (Echo's own Tribunal evaluation exhausted all 3 iterations because the adversarial judge never passed). It is technically correct — strictly more than half of 2 requires 2 — but surprises users expecting "majority" to mean "1 out of 2".

**The consequence is intentional:** two judges is already a lean panel. Requiring both to pass ensures quality signal from both perspectives before accepting. Users who want genuine 2/3 behavior should add a third judge type (e.g., `security`) to the panel — majority with three judges means two must pass, which is materially different from two-judge unanimous.

## Consequences

- The `majority` policy with 2 judges is effectively `unanimous`. This should be documented prominently for users configuring judge panels.
- Adding a third judge type (e.g., `security`) changes `majority` to mean 2/3, which is a meaningfully different bar. Users who want consistent behavior regardless of panel size should specify `gate_policy: "unanimous"` explicitly.
- The `meta_override` policy gives the Meta-Judge final say, bypassing jury vote counts entirely. This is available but not the default — it introduces a single point of failure (Meta-Judge bias or hallucination) that the default policy is specifically designed to avoid.

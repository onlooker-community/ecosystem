# ADR-005: Retire the Stop Gate; Keep the Harness

**Status:** Accepted  
**Date:** 2026-10-04  
**Supersedes:** [ADR-003](003-stop-hook-trigger.md) (Stop hook as the trigger mechanism)  
**Tracked by:** [ONL-103](https://linear.app/onlooker/issue/ONL-103) (`ecosystem-q023x9`)

## Context

[ADR-004](004-drift-threshold-from-measured-spread.md) replaced a guessed `drift_threshold` with a measured one. That made echo truthful. It did not make it useful, and the same measurement said why: between-document signal sd was **0.048** against a within-document noise sd of **0.079** — signal/noise **0.61**. The rubric could not reliably distinguish two *different* documents, and echo's job is to distinguish two *versions of one* document, which is strictly harder.

ONL-103 named two ways out and preferred the second: sharpen the rubric's anchors, or abandon absolute scoring for pairwise comparison. Pairwise was preferred on the reasoning that it "does not require a stable absolute scale, which is precisely what the measurement says is missing."

That reasoning was sound and the prediction was wrong.

## What was measured

`scripts/measure-pairwise-discrimination.sh`, 2026-10-03, `claude-haiku-4-5-20251001`, prompt sha256 `6b583b00…918779`, the same six-file corpus as ADR-004, `--repeats 2`. All 72 calls issued, all 72 parsed, `repeats_dropped` 0 — the run was not degraded.

| metric | value | pre-registered gate | |
|---|---|---|---|
| `self_tie_rate` | **1.000** | ≥ 0.90 | pass |
| `false_discrimination` | 0.000 | — | |
| `cross_antisymmetry` | **0.567** | ≥ 0.80 | **fail** |
| `true_discrimination` | 0.400 | > `false_discrimination` | pass |

Pairwise removed everything it was supposed to remove. Identity was recognized perfectly — 12 of 12 self-comparisons returned `same`, so the risk that a model asked to compare would refuse to call a tie did not materialize at all. Position bias, the failure the both-orders design exists to detect, was **3.3%**.

What failed was stability. **11 of 30 ordered pairs returned a different verdict across two identical repeats** (5/15 `ab`, 6/15 `ba`), and 40% of cross repeats split tie-against-preference. The instability survived the change of format intact; it simply changed units, from a drifting 0.0–1.0 score to a verdict that flips between `same` and `better` on re-run.

## What production showed

The measurement says the mechanism cannot work. The event log says it already wasn't.

`drift_threshold` became 0.28 in `f627834` (2026-09-24). In the ten days following, from `~/.onlooker/logs/onlooker-events.jsonl`:

| | |
|---|---|
| hook invocations | ~1,100 |
| last suite that judged a file | 2026-09-27 |
| `echo.improvement.detected` / `echo.regression.detected` | **0** |

All nine verdicts echo ever emitted date from the 0.05 era, and the largest |delta| it ever observed was **0.24** — below 0.28, so not one of them would fire today. Cost when it did judge: mean **34.3s** of delayed Stop, max 58.9s.

This is structural rather than a tuning accident. With signal sd 0.048 and a threshold of 0.28, echo needed a delta roughly **six times the typical real difference between two different documents** before it would speak. Its sensitivity to genuine drift was approximately zero *by construction* — which is what "honest threshold" means given this judge's noise. ADR-004 did not break echo; it revealed that echo never worked.

## Decision

**Retire the Stop hook.** Delete `echo-stop-gate.sh` and everything whose only caller it was: `echo-events.sh`, `echo-project-key.sh`, `echo-ulid.sh`, the vendored `watch-unmatched.sh`, the `watch_paths` / `exclude_paths` / `drift_threshold` config keys and their accessors, and the six bats files covering the gate.

**Keep the harness.** Both runners, both statistics modules, `echo-judge-prompt.sh`, `echo-config.sh`, the ADRs, and the committed raw verdicts. It measures whether *any* LLM judge discriminates better than it reproduces itself, which is not an echo-specific question — tribunal ships a jury and nothing currently measures its spread.

### Why not a larger model

The spec closed by naming two remaining suspects: the judge (model or sampling) or the question asked of it. The data discriminates between them better than the spec did. Perfect self-tie plus negligible position bias plus 40% cross instability describes a judge that is **reliable on determinate questions and unreliable on indeterminate ones**. "Is version B better than version A" for two competently written documents often has no determinate answer — both are fine, differently — so the instability may be the correct response to an ill-posed question rather than a defect in the model answering it.

A larger model does not make an indeterminate question determinate. It would also make echo more expensive, and expense was already the complaint: echo was the most costly hook in the stack. So the model hypothesis was declined on reasoning, and that reasoning is recorded here rather than left implicit — if someone later wants it measured, `--repeats 2` against a different `evaluation.model` is one command and 72 calls.

### Why not keep it disabled instead

A hook that never fires is indistinguishable from a broken one, and the README promised "every prompt edit a before/after signal instead of relying on intuition" while delivering none. Leaving an inert runtime in place preserves that claim and the maintenance tail without preserving any behavior.

## Consequences

- **The capability is gone, not replaced.** Whether a determinate version is worth building is [ONL-133](https://linear.app/onlooker/issue/ONL-133), which must first settle whether it belongs in cartographer or inspector rather than here.
- **Echo is a plugin with no runtime.** It installs and does nothing. `scripts/lint/check-plugin-liveness.mjs` gained a `no_runtime` verdict for exactly this, kept distinct from `not_running` — whose advice, "check enablement and install", would send a reader after a fault that does not exist. Whether echo should remain a plugin at all is [ONL-134](https://linear.app/onlooker/issue/ONL-134).
- **The `echo.*` event types stay registered** in `@onlooker-community/schema`, so the committed measurement artifacts remain interpretable, and move to `excluded` in `test/bus-coverage.json` with that reason.
- **`echo.watch_paths` left `scripts/lib/repo-shaped-inputs.json`.** It was the original motivating case for that registry (ecosystem-449.15); cartographer is now the only inclusion entry, and the three `check-plugin-liveness` tests that used echo as their real registered case were repointed to it.
- **Existing baselines under `~/.onlooker/echo/` are orphaned** and deliberately left in place. Deleting user data on upgrade is not this change's call.
- **A `drift_threshold` in user settings is now inert.** It is not read, and not respected.

## Alternatives considered

| | Why not |
|---|---|
| Lower `drift_threshold` again | Reintroduces exactly the noise ADR-004 removed. The 0.05 era emitted an improvement and a regression for the same file on the same day. |
| Median-of-5 sampling | Measured: residual noise 0.044 against signal 0.048 — signal/noise ≈ 1, at 5× the cost of the most expensive hook in the stack. |
| Re-measure on Sonnet or Opus | See *Why not a larger model*. Declined on reasoning, cheap to revisit. |
| Loosen `cross_antisymmetry` to only self-contradictory verdicts | Gives 96.7% and flips the verdict, but the strict definition and the 0.80 bar were both pre-registered at commit `14e15c2` before any data existed. Loosening a definition after seeing the result is the failure this project's methodology exists to avoid. The threshold-free finding — 11 of 30 pairs not reproducing — is untouched by the choice anyway. |

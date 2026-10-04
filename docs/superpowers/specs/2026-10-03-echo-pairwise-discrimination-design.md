# Echo Pairwise Discrimination — Measurement Design

**Status:** Complete. Verdict: `stop`.
**Tracked by:** [ONL-103](https://linear.app/onlooker/issue/ONL-103) (`ecosystem-q023x9`).
Follows [ONL-102](https://linear.app/onlooker/issue/ONL-102) (merged), which set
`drift_threshold` to the measured 0.28 and produced the numbers below.
**Scope:** a measurement only. No change to echo's hook, config, or baseline format.

---

## Why

ONL-102 made echo truthful. It did not make it useful, and the measurement says why.

86 judge calls, six files, `claude-haiku-4-5-20251001`, one prompt fingerprint:

| statistic | value |
|---|---|
| between-file sd of means (six *different* documents) | 0.048 |
| mean within-file sd (same document, re-scored) | 0.079 |
| signal / noise | **0.61** |

Six documents by different authors for different purposes span 0.698–0.834 in mean score.
Re-scoring any one of them moves it further than that. **The rubric cannot reliably tell two
different documents apart**, and echo's actual job — telling two *versions of one document*
apart — is strictly harder.

Sampling does not rescue it. Median-of-5 drops residual noise to ~0.044 against a signal of
0.048: signal/noise near 1, at 5× the cost, on what was already the most expensive hook in
the stack.

ONL-103 names two directions and prefers the second: sharpen the rubric, or abandon absolute
scoring for pairwise comparison. Pairwise does not need a stable absolute scale, which is
precisely what the measurement says is missing.

## What this spec decides

Whether pairwise comparison discriminates well enough to be worth implementing — **before**
implementing it. ONL-103's acceptance criterion is itself a measurement:

> echo's evaluation can distinguish two different documents more reliably than it distinguishes
> one document from itself, measured with the same harness.

So the honest first step is to run that measurement against a pairwise judge. If it fails, we
have spent ~72 judge calls instead of a hook rewrite, a baseline migration, and an ADR.

## Corpus

The same six files ONL-102 used, so the result is directly comparable to 0.61 on identical
inputs. Different documents, not synthetic edits.

This is deliberately the *easier* task. Production compares two versions of one file after an
edit; unrelated documents differ far more. Passing here is therefore **necessary but not
sufficient** — but failing here is conclusive, which is what makes it a valid early kill. A
synthetic-edit arm is the natural follow-up only if this clears.

## Experiment

Two comparison classes, each repeated `R` times (default 2):

| class | shape | count at R=2 | measures |
|---|---|---|---|
| **self** | A vs A, identical content | 6 × 2 = 12 | the noise floor. A judge that will not say "same" when shown one document twice is unusable. The pairwise analogue of within-file sd. |
| **cross** | A vs B, both orders | 15 pairs × 2 orders × 2 = 60 | discrimination, and antisymmetry: if `A\|B` says *better*, `B\|A` must say *worse*. |

**Total: 72 judge calls.** The existing spread run is 30. `--repeats` is a flag.

### Position bias is measured, not assumed

Preferring whichever document sits in slot two is the standard failure mode of a pairwise LLM
judge, and it manufactures discrimination that looks excellent and means nothing. Running both
orders is what makes the result interpretable rather than decorative. This is not optional:
the alternative is another number that looks like signal and is not.

### Verdict vocabulary

`{better, worse, same}` plus `confidence`, mapping one-to-one onto the
`improved / degraded / neutral` echo already emits per file. No new output concepts, and the
mapping is more direct than the score-diff it would replace.

## Metrics

Defined before the run, because the first draft of this spec compared two quantities with
different units and asked whether one exceeded the other, which meant nothing. Both headline
rates are expressed as **"the judge reported a difference"**, so they are directly comparable:

| metric | definition |
|---|---|
| `self_tie_rate` | share of self comparisons (A vs A) returning `same` |
| `false_discrimination` | `1 - self_tie_rate`. The judge claimed a difference where there is none. |
| `cross_antisymmetry` | share of cross pairs where the two orders agree: `{better, worse}` pointing at the same document, or `{same, same}` |
| `true_discrimination` | share of cross pairs returning a **consistent, antisymmetric, non-tie** verdict across all `R` repeats |

`true_discrimination` deliberately requires consistency across repeats and across order. A
verdict that flips between runs is not discrimination, and neither is one that only appears in
a single presentation order.

## Kill criterion

Stated before the run, so the result cannot be rationalized after it:

```
self_tie_rate         >= 0.90
cross_antisymmetry    >= 0.80
true_discrimination   >  false_discrimination
```

The third line is ONL-103's done-when restated in pairwise terms, and it is the one that
actually decides the question: can echo tell two documents apart more reliably than it can tell
one document from itself? Both sides are now rates of the same event, measured on the same
corpus, so the comparison is meaningful.

The first two are the thresholds most likely to be wrong — they are proposed, not derived, and a
near-miss on either is a reason to look at the numbers rather than to fail the approach
automatically.

A failure on `self-tie` is the cheapest possible kill: it needs only 12 of the 72 calls, so the
runner evaluates the self class first and stops early if it is already hopeless.

## Code shape

| file | role |
|---|---|
| `plugins/echo/scripts/lib/echo-judge-prompt.sh` | add `echo_build_pairwise_prompt`, beside the existing scoring prompt |
| `plugins/echo/scripts/measure-pairwise-discrimination.sh` | the runner, sibling to `measure-judge-spread.sh` |
| `plugins/echo/scripts/pairwise-stats.mjs` | the arithmetic, sibling to `judge-spread-stats.mjs` |
| `test/node/pairwise-stats.test.mjs` | arithmetic, exhaustively |
| `test/bats/echo-measure-pairwise.bats` | plumbing, against a stubbed `claude` |

The pairwise prompt lives in `echo-judge-prompt.sh` rather than in the runner for the reason
that lib exists: two copies of a prompt drift apart silently, and a measurement taken against a
different prompt does not transfer. Both prompts stamp model and prompt fingerprint into every
run, as ONL-102 established.

A sibling runner rather than a fourth arm inside `measure-judge-spread.sh`: that script's whole
identity is |delta| between independent samples of identical content, and its header documents
it as such. Pairwise is a different experiment producing different statistics, and bolting it
on would leave one script answering two unrelated questions.

Not wired into `npm test`, matching `measure-judge-spread.sh`. A suite that costs 72 judge calls
is one nobody runs; bats covers plumbing with a stub and node covers arithmetic.

## Out of scope

Nothing in echo's runtime changes here. `drift_threshold` stays 0.28, `echo-stop-gate.sh` is
untouched, and baselines keep storing `{path, test_id, score, content_sha256, recorded_at}`.

If the measurement clears the bar, the follow-on work is a separate spec: storing prior
*content* alongside the hash (watched files are 3–5 KB; all 40 total 82 KB, so this is cheap),
swapping the hook's evaluation, and an ADR. Note that path makes `drift_threshold` **obsolete**
rather than retuned — a pairwise judge needs no threshold on an absolute scale, because there is
no absolute scale.

## Risks

- **The thresholds are proposed, not measured.** 0.90 and 0.80 are judgment. The run reports the
  raw rates regardless, so a near-miss is legible rather than a silent fail.
- **Six files give 15 pairs.** Small. The rates will have wide intervals, and the spec treats the
  result as a go/no-go signal, not a precise estimate.
- **Haiku may simply refuse to say "same."** Models are often reluctant to call a tie. If
  `self-tie` fails for that reason rather than for an inability to compare, an explicit "identical
  is expected and common" instruction in the prompt is the first thing to try before concluding
  pairwise cannot work.

---

## Result

Run on 2026-10-03, `claude-haiku-4-5-20251001`, `echo-judge-prompt.sh` at sha256
`6b583b00080f77d5b2a44eb7d6d59412f6f97863ddea7a0cf366b8c801918779`, the six-file corpus
above, `--repeats 2`. All 72 calls were issued and all 72 parsed: `attempted.self_calls`
12, `attempted.cross_calls` 60, `repeats_dropped` 0, `cross_pairs_usable` 15 of 15. The
run was not degraded, so nothing here is an artifact of missing data.

| metric | value | threshold | |
|---|---|---|---|
| `self_tie_rate` | **1.0** | ≥ 0.90 | pass |
| `false_discrimination` | 0.0 | — | |
| `cross_antisymmetry` | **0.5667** | ≥ 0.80 | **fail** |
| `true_discrimination` | 0.4 | > `false_discrimination` | pass |

**Verdict: `stop`.**

### What passed, and it is worth keeping

`self_tie_rate` was **perfect: 12 of 12 self comparisons returned `same`**. The risk this
spec flagged — that a model asked to compare is reluctant to call a tie, and would fail the
self arm for a prompt reason rather than a capability reason — did not materialize at all.
Haiku recognizes identical content as identical, reliably.

ONL-103's literal acceptance criterion also passed: `true_discrimination` 0.4 exceeds
`false_discrimination` 0.0. The judge does distinguish two different documents more
reliably than it distinguishes one document from itself. That question is answered yes.

### Why it still fails, and it is not the reason we expected

The failure is **not position bias**. Classifying all 30 cross repeats:

| class | count | share |
|---|---|---|
| antisymmetric — a directional verdict that correctly reversed | 17/30 | 56.7% |
| **tie vs preference** — one order `same`, the other `better`/`worse` | **12/30** | **40.0%** |
| position bias — both orders said `better` | 1/30 | 3.3% |

Position bias, the failure the entire both-orders design exists to detect and the reason
this spec called two orders non-optional, is **3.3%**. Essentially absent.

What fails instead is stability. Alongside the tie/preference split above, **5 of 15 `ab`
pairs and 6 of 15 `ba` pairs returned a different verdict on the second of two identical
repeats.** Roughly a third of ordered pairs do not reproduce.

### The conclusion, which undercuts both of ONL-103's options

ONL-103 offered two directions: sharpen the rubric's anchors, or abandon absolute scoring
for pairwise comparison. It preferred the second, on the reasoning that pairwise "does not
require a stable absolute scale, which is precisely what the measurement says is missing."

That reasoning was sound and the prediction was wrong. Pairwise removed everything it was
supposed to remove — no absolute scale, identity recognized perfectly, no position bias —
and the instability survived intact. It simply changed units, from a drifting 0.0–1.0 score
to a verdict that flips between `same` and `better` on re-run.

So the noise is **not an artifact of the scoring format**. It is in the judge's assessment
of these documents. That localizes the problem away from both of ONL-103's options:
re-anchoring the rubric reshapes the same unstable judgment into narrower buckets, and
pairwise has now been measured doing exactly that. What is left is the judge itself (model
choice, or sampling) or the question being asked of it.

### Caveat: one metric definition is doing a lot of work

`cross_antisymmetry` counts a tie-against-a-preference as a failure. Counting only
self-contradictory verdicts — both orders naming the same document better — gives
**96.7%** instead of 56.7%, and the verdict would flip to `proceed`.

But the strict `{better, worse}`-or-`{same, same}` definition and the 0.80 bar were both
**pre-registered**, in the pre-run spec at commit `14e15c2`, before any data existed. So
96.7% is the **post-hoc** reading, arrived at by loosening the definition after seeing the
result — not the honest one. This is not rationalizing a guessed threshold; it is declining
to loosen a pre-registered definition after seeing data, which is the opposite failure and
the defensible direction.

The conclusion does not rest on that definitional choice anyway. **11 of 30 ordered pairs
returned a different verdict across two identical repeats** (5/15 `ab`, 6/15 `ba`) — a
threshold-free instability no choice of antisymmetry definition can touch. And the stricter
definition is still the right one for echo's purpose: echo compares two versions of one
document after an edit, so a judge whose tie boundary moves when you swap the inputs cannot
tell "this edit changed nothing" from "this edit made it worse." That is the product
question, and 40% instability on it is disqualifying. A reader who wanted the looser
question answered should know the number both ways rather than discover the threshold was
load-bearing.

### Not written

No ADR. `plugins/echo/docs/adr/005-pairwise-vs-absolute-scoring.md` was conditional on a
`proceed` verdict and does not exist. Nothing in echo's runtime changed; `drift_threshold`
remains 0.28.

Raw artifacts are committed at
`plugins/echo/docs/measurements/2026-10-03-pairwise/`, with the model and prompt
fingerprint stamped, so the run can be compared against a future one on a different model
or prompt — and so the per-pair verdicts behind the classification above can be
recomputed under a different antisymmetry definition without spending 72 calls again.

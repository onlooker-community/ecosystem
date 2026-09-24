# ADR-004: drift_threshold from a Measured Spread

**Status:** Accepted  
**Date:** 2026-09-24

## Context

`drift_threshold` shipped at `0.05`. It was chosen, not measured.

The tree already carried a figure that contradicted it. `echo-stop-gate.sh` and `test/bats/echo-stop-gate-content-skip.bats` both recorded that "a single judge's spread on identical content measured 0.13–0.24 against a drift_threshold of 0.05", with a worked example: one `SKILL.md` baseline walked 0.78 → 0.65 → 0.72 without a single edit. That figure carried no methodology — no sample count, no files, no date, no model — so it could neither be defended nor re-derived when the prompt or model changed.

Echo classifies drift by comparing a **stored single judge sample** against a **fresh single judge sample**:

```text
DELTA      = SCORE_AFTER - SCORE_BEFORE
improved   if DELTA >  drift_threshold
degraded   if DELTA < -drift_threshold
```

So the quantity that should set the threshold is |delta| between two independent samples of identical content — not the standard deviation of scores, and not a number anyone picked.

## What was measured

`scripts/measure-judge-spread.sh`, three runs, `claude-haiku-4-5-20251001`, prompt fingerprint `014cb753d0a6` identical throughout. Six files, 86 usable judge calls.

|delta| between two independent evaluations of identical content, p95:

| content | files | pairs | p50 | p95 | p99 | max |
|---------|-------|-------|-----|-----|-----|-----|
| agent files | 4 | 306 | 0.07 | **0.18** | 0.21 | 0.25 |
| `SKILL.md` files | 2 | 324 | 0.09 | **0.28** | 0.31 | 0.34 |

Per file:

| file | kind | n | p95 |
|------|------|---|-----|
| `plugins/tribunal/agents/tribunal-actor.md` | agent | 10 | 0.16 |
| `plugins/tribunal/agents/tribunal-judge-standard.md` | agent | 19 | 0.17 |
| `plugins/tribunal/agents/tribunal-meta-judge.md` | agent | 10 | 0.18 |
| `plugins/tribunal/agents/tribunal-judge-adversarial.md` | agent | 10 | 0.24 |
| `plugins/lineage/skills/lineage/SKILL.md` | skill | 19 | 0.25 |
| `.claude/skills/writing-tests/SKILL.md` | skill | 18 | 0.29 |

Raw scores on identical bytes, one run:

```text
tribunal-judge-standard.md  0.67 0.70 0.78 0.78 0.78 0.80 0.82 0.82 0.86 0.88
lineage/SKILL.md            0.63 0.68 0.70 0.71 0.71 0.72 0.75 0.76 0.80 0.82
writing-tests/SKILL.md      0.60 0.76 0.77 0.79 0.80 0.87 0.88 0.88 0.89 0.90
```

An earlier run was wider still: `lineage/SKILL.md` produced **0.52 and 0.86 on the same unchanged bytes**.

### The noise exceeds the signal

| statistic | value |
|-----------|-------|
| between-file sd of means (six different documents) | 0.048 |
| mean within-file sd (same document, re-scored) | 0.079 |
| signal / noise | **0.61** |

Six files — four tribunal agents and two skill docs, different authors, different purposes — have means spanning only 0.698 to 0.834. Scoring any one of them twice moves it by more than that.

The rubric cannot reliably distinguish two *different documents*. Distinguishing two *versions of one document* is strictly harder.

## Decision

**`drift_threshold` becomes `0.28`** — the measured p95 pooled across the file kinds `watch_paths` actually covers. `watch_paths` is unchanged.

Echo will be close to silent at this threshold. That is the point: it was previously emitting sampling error as improvements and regressions, and silence is strictly better than false signal.

## Rationale

**Why p95 of |pairwise delta|.** It is exactly the quantity echo computes — a stored single sample against a fresh single sample. Robust to one outlier, unlike `max`, and statable as a false-positive rate rather than "no noise we happened to see." `2 × stddev` was rejected because judge scores cluster on round values like 0.80 and 0.85, so normality is the one assumption not to make. Nearest-rank, not interpolated, so the threshold is always a delta that actually occurred.

**Why pooled rather than the 0.18 agent-file figure.** Narrowing `watch_paths` to agent and command files and using their tighter 0.18 was considered and rejected. Two reasons, both discovered by trying it:

- It re-creates the bug `test/bats/repo-shaped-defaults.bats` exists to prevent. Under ecosystem-449.15, echo shipped `watch_paths` defaulting to `["plugins/*/agents/*.md"]` — a shape describing this marketplace repo and essentially nothing else. Consumers installed it, registered the Stop hook, paid the cost and matched nothing, forever. A repo holding only skill documents would land back there. `onlooker.watch.unmatched` (ecosystem-449.21) means it would at least warn rather than fail silently, but warning is not the same as working.
- It does not express cleanly. Echo's matcher is `[[ $f == $pat ]]`, where `*` crosses `/`, so `.agents/*.md` matches `.agents/skills/beads/SKILL.md` regardless. The narrowing dropped skill files from two layouts and silently kept them in a third — a default meaning something different per layout.

The threshold has to hold for everything `watch_paths` claims. Since it claims skill documents, it takes their wider spread.

**Why not median-of-N sampling.** It was measured: median-of-3 reaches p95 0.12 and median-of-5 reaches 0.10. Both are better, and neither is enough — at 5× the judge cost, median-of-5's residual noise (~0.044) still only matches the 0.048 between-file signal. Buying a signal-to-noise ratio near 1 for five times the cost is not a fix. Echo was already the most expensive hook in the stack.

**Why 0.28 and not a round 0.30.** The stated rule is p95, and the measured p95 is 0.28. Being faithful to the method matters more than roundness; a rounded number is a picked number again.

## Consequences

**Echo will rarely fire.** At 0.28, against the same judge that produced it, roughly one evaluation in twenty crosses the bar from noise alone, and a real change must be very large to register. Anyone reading the event log should expect `echo.suite.complete` with `neutral` verdicts as the normal case, and should not read the absence of drift events as evidence that prompts are stable.

**The rubric fits some watched content better than the rest.** Agent files measured p95 0.18 against 0.28 for skill documents, and the rubric's criteria — role clarity, output format, criterion coverage, internal consistency — were written for agent prompt files. A project that watches only agent files can reasonably set a tighter `drift_threshold` in its own settings. The shipped default cannot assume that.

**The threshold is a property of one prompt and one model.** Change either and it is stale. The prompt lives in `scripts/lib/echo-judge-prompt.sh`, shared with the hook so the two cannot drift apart, and `scripts/measure-judge-spread.sh` stamps the model and a prompt fingerprint into every measurement so a later reader can tell whether the numbers still apply. Re-run it when either changes.

**This does not make echo useful, only honest.** The measurement says the scoring approach cannot support drift detection at any affordable sampling depth. Making echo genuinely informative requires changing what the judge is asked — a sharper rubric, or abandoning absolute scoring for a direct pairwise comparison of two versions, which removes the need for a stable absolute scale altogether. That is tracked as ONL-103.

### Precision

Single-sample p95 was 0.28 in the first run and 0.20 in the second. Ten samples per file buys a p95 with several points of slop, and the skill-file figure this threshold takes rests on two files. `0.28` is the right number to act on from this data; it is not precise to 0.01, and a re-run would be expected to move it somewhat.

### Confound

All four agent files come from tribunal, written by one author in one style. The data supports "these agent files are more stably scored than these skill files"; it does not establish that agent files in general are. A wider sample could narrow the gap.

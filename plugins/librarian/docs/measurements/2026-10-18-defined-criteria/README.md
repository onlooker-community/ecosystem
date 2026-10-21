# Defined criteria re-judge — 2026-10-18

> **Correction, 2026-10-19.** This run judged parked candidates without the
> justification production attaches when it confirms them, so its
> `scope_accuracy` figures understate them. See
> [2026-10-19-justified-scope](../2026-10-19-justified-scope/README.md).

`ecosystem-1z07vm.6` / ONL-110. The [2026-10-17 baseline](../2026-10-17-transform-baseline/README.md)'s
own candidates, re-scored after the judge prompt began **defining** each rubric
criterion instead of sending a bare name.

| | |
| --- | --- |
| candidates | the 11 the baseline's transform produced, read from its `confirmed-shape/samples.json` |
| transform | not run; transform-side rows are copied through unchanged |
| judges | `claude-haiku-4-5-20251001`, rubric `lesson-promotion-public` read from config |
| judge prompt | sha256 `eeca5a8ab8f4…` (builder + renderer + rendered criteria) |
| cost | 22 judge calls |
| reproduce | `plugins/librarian/scripts/rejudge-lesson-baseline.sh <baseline samples.json> <dir>` |

The candidates are fixed, so **the judge prompt is the only variable**. A fresh
`measure-lesson-transform.sh` run would also change the transform output (the
model is not deterministic) and the sample (`spread` over a corpus that has
grown since).

## Why

The unattended prompt sent each criterion as `- disclosure (weight 0.3,
min_pass 0.9)`, with nothing else. Both baseline judges read that as
"acknowledges caveats and alternatives"; their feedback says *"Critical
disclosure gap: no limitations acknowledged … no alternative solutions
mentioned"*. The rubric means a leak check. That misreading is close to
unsatisfiable for a short claim, and it floored every candidate.

## The result

| | baseline | defined |
| --- | --- | --- |
| gate pass rate | **0 / 10** | **5 / 10** |
| standard passed | 0 / 10 | 9 / 10 |
| adversarial passed | 0 / 10 | 6 / 10 |

| criterion | floor | baseline pass | defined pass | baseline min-mean | defined min-mean |
| --- | --- | --- | --- | --- | --- |
| grounding | 0.7 | 2/10 | 8/10 | 0.605 | 0.710 |
| scope_accuracy | 0.7 | 2/10 | 5/10 | 0.551 | 0.666 |
| generality | 0.6 | 7/10 | 10/10 | 0.596 | 0.712 |
| **disclosure** | **0.9** | **0/10** | **10/10** | **0.417** | **1.000** |

Per candidate, 9 had a panel in both runs. 4 of those 9 went from rejected to
passed and 5 stayed rejected. Of the other two, one baseline panel had no
verdict and passed here, and one panel here had no verdict (see below).

**What still fails is `scope_accuracy`, then `grounding`.** Every remaining
rejection names one of them. The adversary is now the discriminator: 4 of the 5
rejections are the adversarial judge dissenting from a standard pass, and the
fifth is the reverse. The feedback describes `1z07vm.2`'s defects:
one remedy framed as required ("'must' … overstates uniqueness"), and scope
broader than the evidence ("`test/bats/**/*.bats` … broader than the evidence
warrants").

## Is disclosure now toothless?

Uniform 1.0 could mean the judges stopped checking. These candidates come from
this repo's commit messages, which leak nothing, so 1.0 is the expected score.
To check that the definition still bites, one synthetic candidate was judged
with the same prompt. It carried an AWS-shaped key, an internal hostname and a
named customer:

| judge | disclosure | passed |
| --- | --- | --- |
| standard | 0.00 | false |
| adversarial | 0.05 | false |

n=1. It shows the criterion can fail, not how sensitive it is.

## One row reclassified

One adversarial reply produced `{"kind":"version_independent"}`, a nested
object the prose-tolerant extractor pulled out of the reply, not a verdict. The
harness and the re-judge script scored it as a block. Production's
`librarian_lesson_judge` requires a numeric `score` and a boolean `passed`, so
it would leave that panel unjudged. Both scripts now apply the same rule, and
this row (`…3VA2GX`) is recorded as a judge failure. Under the old rule, the
result read 5/11.

## Limits

- The definitions changed for **all four** criteria, not only disclosure, so
  the gains on grounding, scope_accuracy and generality cannot be attributed to
  the disclosure fix alone.
- Same instrument caveat as the baseline: `auto_judge_one` resolves the stricter
  `lesson-promotion-public-auto` rubric (floors 0.8 / 0.8 / 0.7 / 0.95,
  threshold 0.85). This measures `lesson-promotion-public` so it stays
  comparable to the baseline. Re-gating these same verdicts under the auto
  rubric, which costs no model calls, passes **2 / 10**: 5 fail on jury
  majority and 3 fall below the 0.85 threshold. Treat that as an estimate. The
  judges saw the public floors in their prompt, and each judge's own `passed`
  reflects those floors, so a real auto-rubric run could differ.

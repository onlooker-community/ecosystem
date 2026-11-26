# The self-check on real lessons — 2026-11-26

ONL-311 proposed a second model call that rejects an unattended
version-independence justification when it defends a broader principle than
its claim, or when the claim rests on tool behavior a release could change.
This measures whether such a call can tell the lessons a person vetoed from
the ones that stand. It can't, reliably, and the self-check was not shipped.
The design that replaces it is
[`2026-11-26-evidenced-lesson-portability-design.md`](../../../../../docs/superpowers/specs/2026-11-26-evidenced-lesson-portability-design.md).

| | |
| --- | --- |
| model | `claude-haiku-4-5-20251001`, librarian's `lesson_transform.model` |
| lessons | `ids.tsv`, every `version_independent` proposal in the store on 2026-11-26: vetoed 6, kept 1, human 4, rejected 39 |
| groups run | **vetoed** (model-asserted, jury-approved, vetoed by hand), **kept** (model-asserted, approved, not vetoed), **human** (human-asserted, approved). **rejected** was not run |
| input | each lesson's claim, stack and stored justification, through `librarian_lesson_auto_self_check_prompt` |
| isolation | the lesson store is read, never written. Each call passes `--settings '{"disableAllHooks":true}'` |
| samples | one call per lesson per attempt |

`run.sh <group>...` appends one row per lesson to `results.jsonl`. It sources
the self-check prompt builder, which exists only on the ONL-311 branch at
`f77aef9e` plus the prompt edits below; it does not run on `main`. Each
attempt's output is committed as `results-attempt-<n>.jsonl`.

## Results

| | Attempt 1 | Attempt 2 | Attempt 3 |
| --- | --- | --- | --- |
| vetoed failed (target: at least 5 of 6) | 6 | **5** | 3 |
| kept failed (target: 0 of 1) | 1 | 0 | 1 |
| human failed (target: 0 of 4) | 4 | 3 | 3 |
| total cost | $0.66 | $0.76 | $0.74 |
| median per call | $0.059 | $0.070 | $0.063 |

No attempt met both targets. Five approved lessons are too few to give a
false-fail rate, but every attempt that caught the vetoed lessons also failed
at least three of the five.

## What each attempt asked

The prompt has two numbered checks and fixed answer instructions. Only the
text of the checks changed.

**Attempt 1**, as committed in `30f6dd2c`:

> 1. Does the justification argue for the claim as written, or for a more
> general principle the claim is one instance of? A justification that would
> defend a different claim built on the same principle just as well is
> arguing for the principle. FAIL it.
>
> 2. Work out which behaviors of external tools the claim relies on: the tools
> in its stack, and any tool the claim itself names. If any of those behaviors
> is something a release of that tool could change, the claim is not
> version-independent. FAIL it.

Nine of the eleven verdicts cited check 1. Almost every honest
version-independence argument rests on a rule that would defend other claims
too, so "would it defend a different claim just as well" is nearly always
yes.

**Attempt 2** replaced check 1 and kept check 2:

> 1. Find the part of the claim that carries it: the fact that, if it stopped
> being true, would make the claim wrong. Does the justification give a reason
> that part holds regardless of version? Arguing from a more general principle
> is fine, and expected, when that principle covers the part that carries the
> claim. FAIL only when the justification argues for some other part, or a
> true rule beside it, and leaves that part unargued.

The POSIX lesson (01M4PD9CBE) passed, and 01M6FJ2S failed for the reason a
person vetoed it. Several fails came from check 2 on speculative grounds,
such as "a release of jq could add a daemon mode".

**Attempt 3** kept attempt 2's check 1 and bounded check 2:

> 2. … Count only a behavior the tool's makers chose and could choose
> differently, such as a name, a limit, a default, an output format, or how it
> passes values to other programs. Behavior fixed by a standard, by
> arithmetic, or by how processes work does not count. Nor does a feature a
> release might add: that would make the advice unnecessary, not wrong. …

Two vetoed lessons about batching jq and node calls then passed, correctly
under the new wording: process startup cost is how processes work. Whatever
made a person veto them was not a tool behavior a release could change. The
veto events record only whether a reason was given, so the reason isn't
known.

## The approved lessons that failed in attempt 2

| Lesson | Group | Verdict, in short | Read |
| --- | --- | --- | --- |
| 01M624MTJM | human | the claim names Sentry trigger identifiers the justification itself says "may change" | a correct fail; the approval looks wrong |
| 01M5KEZG3R | human | the claim rests on D1's bound-parameter limit, a vendor choice | check 2 working as designed |
| 01M5KF54HR | human | the justification argues about the app, not about versions | a weak justification for a sound lesson |

## Noise

01M5KDAW5B (kept) passed in attempt 2 and failed check 1 in attempt 3, though
check 1 was the same text in both. With one sample per lesson, a single flip
between attempts is not a signal.

## Answer form

Every answer started with `PASS` or `FAIL`, but two of attempt 2's three
passes were `PASS: <reason>` and `PASS  <reason>`. The committed parser
accepted only `PASS` and `PASS.`, so production would have read them as
unavailable, never recorded them, and paid for both calls again on every
scan.

## Cost

A self-check costs about what one judge does ($0.056–0.081 in the 2026-10-24
run), not the fraction of a jury the bead assumed. It would pay for itself
only on candidates the jury was going to reject anyway.

## What follows

The question "does this justification really show version independence?"
has no reliable answer from this model, and possibly from any single call:
the vetoed lessons were true where they were learned, and their universal
justifications were invented to clear the bar. The replacement design stops
asking it. Lessons record the versions they were observed on, local
knowledge goes to memory, and a lesson becomes portable through a person's
nomination or by recurring in a second project.

For ONL-198: the self-check gives no reason to keep `lesson_auto`'s justify
path enabled.

## Not measured

- **rejected**, the 39 lessons the jury already rejected. That run would have
  measured how many a self-check would have held before a jury paid for them.
- More than one sample per lesson, which would separate noise from signal.

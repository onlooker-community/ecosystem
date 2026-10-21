# Justified scope — 2026-10-19

`ecosystem-1z07vm.2` / ONL-110. Set out to measure three claim constraints in
the transform prompt. Found that the harness had been judging parked
candidates without the justification production attaches, and fixed that
first. **The two directories here are the first runs on the corrected
instrument.** Every earlier record understates `scope_accuracy` for parked
candidates.

| | |
| --- | --- |
| corpus | **pinned**: the 36 artifacts of the [2026-10-17 baseline](../2026-10-17-transform-baseline/README.md), copied out and passed via `--artifacts-from` |
| transform + judges | `claude-haiku-4-5-20251001`, rubric `lesson-promotion-public` |
| judge prompt | sha256 `eeca5a8ab8f4…`, unchanged from [2026-10-18](../2026-10-18-defined-criteria/README.md) |
| `control/` | transform prompt sha256 `0bce5c6f74ea…`, the prompt before this task |
| `arm-b/` | transform prompt sha256 `e27a4e521506…`, the prompt this task ships |

Pinning the corpus is what makes two arms comparable. `spread` over the live
store picks different artifacts once the store grows, and it has grown since
2026-10-17.

## The instrument bug

Production confirms a parked candidate through `librarian_lesson_confirm`,
which writes `{kind: "version_independent", justification: <one sentence>}`
(`librarian-lesson-review.sh`). The harness rewrote the scope to a bare
`{"kind":"version_independent"}` and skipped the justification call, on the
stated grounds that it "does not change the candidate the panel sees". It does:
the sentence is part of the scope the judges read.

Without it, the panel sees "a MODEL asserted that this lesson holds regardless
of version" with no reason given, and marks it down. On the old harness, all 9
`scope_accuracy` floors in the control arm cited exactly that missing support.

The harness now calls `librarian_lesson_auto_confirm_one` itself, inside its
sandbox store. A refused justification (`REFUSE`) is recorded in
`confirm_outcome` and not judged, because production leaves that candidate
pending and never convenes a panel for it.

## Results

All four runs used the same 36 artifacts and the same judge prompt.

| | old harness, control | old harness, rules 1–4 | old harness, arm B | **control** | **arm B** |
| --- | --- | --- | --- | --- | --- |
| proposed | 14 | 8 | 13 | 15 | 13 |
| `schema_invalid` | 3 | **9** | 2 | 2 | 3 |
| justification refused | not run | not run | not run | **10** | **9** |
| juried | 13 | 7 | 11 | 5 | 4 |
| gate pass | 5/13 | 1/7 | 0/11 | **3/5** | **2/4** |

Only the last two columns are committed. The old-harness runs are kept here as
a table because they explain two decisions, not because their numbers hold.

**What the corrected instrument shows:**

1. **Most of the `scope_accuracy` failure was the instrument.** With the
   justification present, 2 floors remain in the control arm, down from 9.
2. **The binding gate in production is the justification step, not the
   jury.** It refuses about 70% of parked candidates (10 of 14, 9 of 12), and
   a refused candidate waits for a human. About 4–5 of every 36 artifacts
   reach a panel at all.
3. **The prompt change is not shown to help or hurt.** 2/4 against 3/5 is
   inside noise at this n.

## Why rule 3 is not in the shipped prompt

The task asked for three constraints. The third, "do not restate one
project's pattern as a general rule; leave this project's names out of the
claim", made the model empty `stack` as well. The validator requires a
non-empty `stack`, so `schema_invalid` went from 3 to 9 and proposals fell
from 14 to 8. Arm B drops that rule and adds an explicit "stack always lists
at least one tool". `schema_invalid` came back to 2, and to 3 on the corrected
harness's run, against the control's 2.

The generality concern rule 3 targeted is still covered on the judge side: the
`generality` criterion now defines "a pattern specific to one codebase
restated as a general rule" as a failure (2026-10-18).

## What ships, and on what evidence

- **The harness fix** ships on the evidence above. It changes what every
  earlier `scope_accuracy` figure means.
- **The arm B prompt** ships on weaker evidence: it removes the stack defect
  that rule 3 caused, and on the corrected instrument it is indistinguishable
  from the control. It is not shown to improve the pass rate.

## Limits

- n=5 and n=4. Telling a 10-point difference apart would take roughly three
  times the corpus. The pinned 36 are a fixed set; a larger pinned set would
  need to be built from the live store.
- The transform model is not deterministic, so a re-run of either arm will
  differ. The refusal rate (about 70% in both) is the most stable figure here.
- Rubric is `lesson-promotion-public`, for comparability with 2026-10-17 and
  2026-10-18. Production's unattended path resolves the stricter
  `lesson-promotion-public-auto`.

## Re-measuring

```bash
# pin a corpus: copy the artifact files a recorded run used
jq -r '.candidates[].artifact_id' <recorded samples.json>   # then copy each file

plugins/librarian/scripts/measure-lesson-transform.sh --samples 36 \
  --artifacts-from <pinned dir> --project-key ee2cfbe428c7 --out <dir>
```

Run `biome format --write <dir>` on the output before committing it, and
replace `corpus` with a description, since the harness stamps the
`--artifacts-from` path verbatim.

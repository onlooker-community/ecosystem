# Lesson transform baseline — 2026-10-17

Raw artifacts from the ONL-110 / `ecosystem-1z07vm.1` baseline run.
`claude-haiku-4-5-20251001` for both the transform and the judges, rubric
`lesson-promotion-public` read from `plugins/librarian/config.json`.

| | |
| --- | --- |
| corpus | 1035 archivist artifacts for project `ee2cfbe428c7`, `--sample-mode spread` |
| transform prompt | `librarian-lesson-transform.sh` at sha256 `0bce5c6f74ea…` |
| judge prompt | `librarian-lesson-auto.sh` at sha256 `ab787b23eea0…` |
| cost | 36 transform calls + 20 judge calls per arm |

**`confirmed-shape/` is the baseline.** `raw-scope/` is a comparison arm kept
only to justify the methodology below; do not quote its numbers.

## The result

36 artifacts attempted, 11 produced a candidate, 10 reached a panel.

| | |
| --- | --- |
| gate pass rate | **0 / 10** |
| gate reason | `jury_not_majority`, all 10 |

| judge | passed | mean score |
| --- | --- | --- |
| standard | **0 / 10** | 0.642 |
| adversarial | **0 / 10** | 0.556 |

| criterion | floor | pass | min-mean | standard mean | adversarial mean |
| --- | --- | --- | --- | --- | --- |
| grounding | 0.7 | 2/10 | 0.605 | 0.717 | 0.620 |
| scope_accuracy | 0.7 | 2/10 | 0.551 | 0.679 | 0.556 |
| generality | 0.6 | 7/10 | 0.596 | 0.662 | 0.600 |
| **disclosure** | **0.9** | **0/10** | **0.417** | 0.527 | 0.470 |

Transform side, over all 36:

| outcome | n |
| --- | --- |
| `declined:no_resolution` | 13 |
| `declined:no_versions` | 10 |
| `declined:schema_invalid` | 2 |
| `proposed` (all parked `unscoped`) | 11 |

## What this changes about ONL-110

**The issue's premise does not survive the batch.** ONL-110 is titled
"transform claims pass the structural validator and the standard judge, then
fail adversarial review," on n=2. At n=10 the standard judge passes **nothing**
either. The adversary is genuinely harsher — grounding 0.717 → 0.620,
scope_accuracy 0.679 → 0.556 — but that difference never decides anything,
because `disclosure` is 0/10 for *both* judges at a min-mean of 0.417 against a
0.9 floor. Disclosure gates every candidate before the two judges disagree.

Two consequences for the sibling tasks:

- `1z07vm.3` ("add a pre-jury **adversarial** self-check") is scoped around the
  adversary being the discriminator. It is not. A self-check that only
  anticipates adversarial findings would leave the actual blocker untouched.
- `disclosure` is not mentioned anywhere in ONL-110's body, and it is the
  criterion to fix first. The body's cited floors (grounding 0.88,
  scope_accuracy 0.85, generality 0.85) appear nowhere in config; the live
  floors are 0.7 / 0.7 / 0.6 / 0.9.

**The raw material is part of the problem**, as the bead suspected — but not in
the direction it guessed. Proposal rate by detail-length quartile:

| quartile | detail chars | proposed |
| --- | --- | --- |
| Q1 | 20–253 | 2/9 |
| Q2 | 294–793 | **6/9** |
| Q3 | 841–1325 | 4/9 |
| Q4 | 1392–3281 | 2/9 |

The **richest** artifacts transform worst, tied with the thinnest, and among
judged candidates there is no quality trend with length: the best claim (mean
0.736) came from a 735-char artifact while the longest (3281 chars) scored
0.508 with the worst disclosure in the set (0.18). So a dedicated
`--sample-mode richest` arm would be expected to look *worse*, not better. The
bead's mechanism — rich artifacts are implementation write-ups, and their claims
come out as descriptions of work — is supported. Its implicit hope that better
raw material would fix the claims is not.

Also: 23 of 36 artifacts declined for `no_resolution` or `no_versions`. Two
thirds of the corpus cannot produce a lesson at all, which is why a run needs
roughly 3× oversampling to reach N≥10.

## Methodology, and why `confirmed-shape` is the one to read

`librarian_lesson_auto_stage` runs `auto_confirm_one` **before**
`auto_judge_one`, and that step rewrites a parked candidate's scope from
`{"kind":"unscoped"}` to `{"kind":"version_independent"}`. The judge prompt then
asserts "a MODEL asserted that this lesson holds regardless of version" — true
of the confirmed shape, false of the raw one.

The first run judged the raw parked candidate, so the prompt asserted a claim
the candidate did not make. Measured on three candidates, one judge each:

| candidate | raw `unscoped` | `version_independent` |
| --- | --- | --- |
| 0 | 0.640 | 0.669 |
| 1 | 0.620 | 0.743 |
| 2 | 0.660 | 0.673 |

Higher in 3/3, with `scope_accuracy` about +0.11 and `grounding` about +0.05
every time. The consistency of direction is the evidence here, not the
magnitudes — a single re-score of one document moves this rubric family by
~0.08 (echo's ADR-004), so any one of those deltas is within noise.

The arm-to-arm shift agrees: every criterion's min-mean rose when the shape was
corrected (grounding 0.551 → 0.605, scope_accuracy 0.500 → 0.551, generality
0.568 → 0.596, disclosure 0.358 → 0.417). **No verdict flipped** — the
corrections are ≤0.06 against gaps of 0.10–0.48 — which is why the conclusions
above are robust to the confound even though the numbers are not.

### Known limits of this measurement

- **The rubric is not the one this code path resolves.**
  `auto_judge_one` always calls `librarian_lesson_rubric_id_for_visibility <v>
  model`, which returns `lesson-promotion-public-auto` (floors 0.8/0.8/0.7/0.95,
  threshold 0.85) — strictly harder than the `lesson-promotion-public` measured
  here, which the bead's acceptance criteria named. Since the pass rate is 0%
  under the looser rubric it is 0% under the stricter one too, so the headline
  is unaffected; the per-criterion pass rates would only fall.
- **This is not the panel that produced the n=2 evidence.** That came from the
  attended `/librarian lessons judge` walk, which dispatches judges via the Task
  tool with repo access. These judges are told the candidate is self-contained
  and use no tools (ONL-168). The two panels are different instruments and a
  verdict from one should not be compared to the other.
- **One proposal of 11 never got a panel** — a judge returned an empty response,
  which is infrastructure rather than a verdict. It is excluded from `n` rather
  than counted as a failure.
- **`gate.failed_criterion` is order-biased.** `librarian_lesson_gate` names only
  the *first* floored criterion in rubric order, so that histogram ranks the
  rubric's declaration order, not severity. Read the per-criterion block.
- **The justification call is not reproduced.** `auto_confirm_one` makes one
  model call to justify a parked claim; it gates whether confirmation happens and
  does not change the candidate the panel sees, so the harness skips it.

## Re-measuring

```bash
# the baseline, as recorded
plugins/librarian/scripts/measure-lesson-transform.sh --samples 36 --out <dir>

# the comparison arm
plugins/librarian/scripts/measure-lesson-transform.sh --samples 36 --raw-scope --out <dir>

# the plan and the call budget, spending nothing
plugins/librarian/scripts/measure-lesson-transform.sh --dry-run --samples 36
```

Sample selection is deterministic, so a re-run after a prompt change scores the
same artifacts. Keep `--samples 36` and `--sample-mode spread` for the result to
be comparable to this one.

`biome check` covers `**`, and the harness writes `jq`-shaped JSON that its
formatter rejects, so run `biome format --write <dir>` on the artifacts before
committing them or `npm run test:ci` fails on formatting. It only normalizes
whitespace and trailing zeros in numeric literals (`0.50` → `0.5`); the four
artifacts here were checked deep-equal as parsed JSON before and after.

| file | contents |
| --- | --- |
| `confirmed-shape/samples.json` | every candidate, verdict, aggregate and gate, plus both prompt shas |
| `confirmed-shape/stats.json` | the computed rates |
| `raw-scope/*` | the same, for the pre-fix shape — methodology evidence only |

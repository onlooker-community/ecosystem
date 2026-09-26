# Automatic Lesson Promotion — Design

**Status:** Approved, not started.
**Tracked by:** not yet filed. Reopens part of
[ONL-13](https://linear.app/onlooker/issue/ONL-13); depends on
[ONL-107](https://linear.app/onlooker/issue/ONL-107) (merged, #384) and relates to
[ONL-110](https://linear.app/onlooker/issue/ONL-110).
**Supersedes, in part:** ONL-13's rule that only a human may assert a lesson holds for
every version. See Decisions D1.

---

## Why

ONL-107 made the intake reachable. Two candidates then went all the way to a jury, and both
were rejected:

| | standard | adversarial | floors violated |
|---|---|---|---|
| ARG_MAX (`01M3FAN035…`) | 0.90 pass | 0.78 fail | `scope_accuracy` 0.85 / **0.52** |
| curator (`01M3FAKEQK…`) | 0.85 pass | 0.615 fail | `grounding` **0.55**, `scope_accuracy` **0.35**, `generality` **0.50** |

The finding that motivates this design is not that the gate is too strict. It is **who was the
weaker filter**. A human confirmed both lessons; the jury then correctly rejected both, catching
a version-dependence overreach and a claim that contradicted the regex quoted beside it. The
human assertion supplied ceremony. The adversarial judge supplied the safety.

Meanwhile every step that costs anything requires that human: `confirm` needs an explicit
visibility and a hand-written justification, and the jury needs a per-run go-ahead. Nothing
reaches the pool unless someone is sitting there.

## What changes, in one line

The model supplies the justification and the jury runs unattended, judged against a stricter
rubric and held locally for a veto window before `sync` can ship it.

## Decisions

**D1. A model may assert version-independence; its assertion is judged harder and held
longer.** This is the reversal. ONL-13 reserved that assertion for a human plus a unanimous
jury. The empirical record above is that the human half of that pair was not doing the work.
Rather than delete the guarantee, this replaces it with two mechanisms that do not require
anyone to be present: a stricter rubric selected *because* a model asserted it, and a window
during which nothing leaves the machine.

**D2. The auto path reuses the human path verbatim. No validator changes.** The transform still
emits `scope: {kind: "unscoped"}` on the unscoped route — a model still never mints
`version_independent` through `librarian_lesson_validate_candidate`. An auto-confirm step then
supplies a model-written justification through `librarian_lesson_confirm`, which already
rewrites the scope and validates with `librarian_lesson_validate_confirmed`.

The two-validator asymmetry shipped in #384 therefore survives completely intact. What changes
is who calls `confirm`, not what the validators permit.

**D3. `asserted_by` lives in the proposal envelope, never in the candidate.** The vendored
`lesson-applies-to.subschema.json` declares both `scope` branches
`additionalProperties: false`, so a field added inside `scope` would break the published pool
contract and force a change in the `onlooker` repo. It also does not belong there: who asserted
a scope is provenance about the *decision*, not part of the lesson. The envelope
(`{id, status, visibility, artifact_id, candidate, …}`) is librarian-local and the right home.

**D4. The jury dispatches named agents from bash, via `claude -p --agent`.** ADR-002 has
librarian dispatch `tribunal-judge-standard` and `-adversarial` **by name** and forbids sourcing
anything under `plugins/tribunal/`. That works today because a skill drives it with the Task
tool, which a detached worker cannot use. `--agent` closes the gap — verified on this machine:

```
claude -p --max-turns 1 --model claude-haiku-4-5-20251001 \
  --agent tribunal-judge-standard 'Reply with exactly: AGENT_RESOLVED'
→ AGENT_RESOLVED
```

So the automatic jury reuses the published definitions rather than inlining copies of their
prompts, and ADR-002 needs no amendment.

**D5. The window is a directory, so `onlooker sync` needs no change.** `sync` reads
`librarian/<key>/lessons/approved/*.json` and nothing else — `apps/cli/src/lessons.ts:46`
states it explicitly ("`approved` only. `proposals/` holds candidates awaiting judgment"). A
model-asserted lesson is therefore promoted into `approved_held/` and moved to `approved/` by a
SessionStart sweep once its window elapses. The entire feature stays in this repo.

**D6. All of it runs in the detached worker, never on the SessionEnd path.** ADR-003 is
unambiguous: no LLM call happens on that path. Auto-confirm and the jury are LLM work, so they
belong in `librarian-classify-worker.sh` beside the transform, under the same detached-spawn
discipline and per-call timeout.

**D7. Off by default.** `lesson_auto.enabled` defaults to `false`. This is a behavioral
reversal on a substrate that publishes to other people; shipping it on would make every existing
installation start asserting version-independence unattended. Opt-in mirrors ADR-001's
`auto_promote`.

## Architecture

```
detached worker (librarian-classify-worker.sh)
  stage 5  transform            → proposal, scope {kind: unscoped}, status pending
  stage 6  auto-confirm  [NEW]  → model writes a justification
                                  librarian_lesson_confirm <id> <visibility> --justification …
                                  envelope records asserted_by: "model"
  stage 7  auto-jury     [NEW]  → claude -p --agent tribunal-judge-standard
                                  claude -p --agent tribunal-judge-adversarial
                                  rubric chosen by (visibility, asserted_by)
                                  existing aggregate → gate → promote
                                     ↓ rejected           ↓ approved
                                  declined ledger       approved_held/  (shippable_after)

SessionStart
  sweep [NEW]  approved_held/ → approved/  for anything past shippable_after
  surface one line: "N lessons leave this machine in Xh — /librarian lessons queue"

onlooker sync   reads approved/ only. Unchanged.
```

Each new stage is skipped entirely when `lesson_auto.enabled` is false, so the disabled path is
the current path.

### Auto-confirm

One `claude -p` call per candidate, given the claim, rationale, `evidence.resolution` and
`applies_to`, asked for a one-sentence justification for why the lesson holds regardless of
version — or a refusal. A refusal leaves the candidate `pending` for a human, which is exactly
today's behavior and the safe direction.

The prompt must carry the two lessons ONL-110 records, because they are what the adversarial
judge attacks: do not assert one remedy is required when others exist, and do not claim anything
the cited evidence does not show.

`librarian_lesson_confirm` gains an optional trailing `asserted_by` (default `"human"`), written
into the envelope. Nothing else about it changes.

### The strict rubric

`librarian_lesson_rubric_id_for_visibility` becomes
`librarian_lesson_rubric_id_for <visibility> <asserted_by>`. Human-asserted lessons keep
today's rubrics unchanged — the path that works is not penalized.

**A model-asserted lesson selects `lesson-promotion-public-auto` at every tier, including
`org`.** The org rubric omits `disclosure` entirely, on the reasoning that an org audience is
trusted and a human read the text before it went. Neither half holds once nobody is present, so
the unattended path always carries the disclosure criterion. `private` remains the exception it
already is: it runs no jury, so auto-confirm skips it rather than inventing one.

The auto rubric is identical to the public one in criteria and weights, with raised floors, and
the gate's aggregate threshold rises from 0.75 to 0.85:

| criterion | weight | human floor | model floor |
|---|---|---|---|
| grounding | 0.32 | 0.70 | **0.80** |
| scope_accuracy | 0.24 | 0.70 | **0.80** |
| generality | 0.14 | 0.60 | **0.70** |
| disclosure | 0.30 | 0.90 | **0.95** |

The floor is the *minimum* across judges, not the mean (`librarian_lesson_gate`), so one
adversarial finding is still decisive. Note what these numbers mean against the record: neither
rejected lesson would have come close, and the curator lesson's standard-judge scores (0.88 /
0.75 / 0.85 / 0.92) would have failed three of the four model floors on their own. That is
intended. An unattended assertion should have to clear a bar a human-attended one does not.

### The veto window

`lesson_auto.veto_window_hours`, default **72**. On promotion of a model-asserted lesson the
envelope gains `shippable_after` (RFC3339, `promoted_at` + window) and the file is written to
`approved_held/`. The SessionStart sweep moves anything past its `shippable_after` into
`approved/`. A human-asserted lesson goes straight to `approved/` as it does today.

Two new verbs: `librarian_cli lessons queue` lists held lessons with time remaining, and
`librarian_cli lessons veto <id> [reason]` deletes the held file and writes a tombstone so the
same content is not re-proposed.

The sweep lives in `plugins/librarian/scripts/hooks/librarian-session-start.sh` and **runs
regardless of `lesson_auto.enabled`**. Gating it on the flag would strand every held lesson the
moment the flag was turned off — written, judged, approved, and invisible forever. The sweep is
deterministic file movement, not LLM work, so it is safe on the SessionStart path.

It is idempotent and crash-safe: one `mv` per file, and a file already in `approved/` is simply
not in `approved_held/` to move.

### Cost

Auto-confirm is one cheap call per candidate. The jury is two agent calls per candidate and is
the expensive step, so it is capped: `lesson_auto.max_juries_per_scan`, default **1**. The cap
is counted in the worker loop the way `unscoped_per_scan` already is, and an over-cap candidate
stays `confirmed` for the next scan rather than being declined — a decline is terminal
(`librarian_lesson_seen` reads `declined.jsonl`), so cost control must never write one.

## Config

```json
"lesson_auto": {
  "enabled": false,
  "visibility": "org",
  "veto_window_hours": 72,
  "max_juries_per_scan": 1,
  "judge_model": "claude-haiku-4-5-20251001"
}
```

`visibility` defaults to `org`, not `public`. An unattended pipeline's first destination should
be the tier with a smaller audience; moving to `public` is a deliberate edit, and the strict
rubric exists for when it is made.

## Failure taxonomy

| outcome | meaning | terminal? |
|---|---|---|
| auto-confirm refuses | no defensible justification; stays `pending` for a human | no |
| over `max_juries_per_scan` | cost control; stays `confirmed` | no |
| jury rejects | gate blocked on a floor or the threshold | yes |
| judge call returns nothing | infrastructure; stays `confirmed`, re-judged later | no |
| vetoed | human killed it during the window; tombstoned | yes |
| swept | window elapsed; now in `approved/` and syncable | — |

## Testing

bats, per `test/bats/librarian-lesson-*.bats` conventions, with the `claude` stub pattern
`_transform_setup` already uses and a second stub branch per judge agent:

1. With `enabled: false`, none of the new stages run and a candidate stays `pending` — the
   disabled path is byte-for-byte today's path.
2. Auto-confirm writes `asserted_by: "model"` and a `version_independent` scope, and the
   candidate's `versions` key is gone (the stale-key rule at `librarian-lesson-review.sh:168`).
3. Auto-confirm refusing leaves the candidate `pending` and writes no decline.
4. Rubric selection returns `lesson-promotion-public-auto` for `(public, model)` and today's
   rubric for `(public, human)`.
5. A model-asserted lesson scoring 0.75 on `scope_accuracy` — which passes the human floor —
   is rejected under the model floor. This is the test that proves the stricter bar is real.
6. An approved model-asserted lesson lands in `approved_held/` with a `shippable_after`, and
   **not** in `approved/`.
7. The sweep moves a held lesson whose window has elapsed and leaves one whose window has not.
8. `lessons veto` removes a held lesson and writes a tombstone.
9. The jury cap stops at N and writes no decline record.
10. A human-asserted lesson still goes straight to `approved/`, unheld — the existing path is
    not disturbed.

## Shipping order

The two backstops are independent and separately shippable, which is worth knowing if this needs
splitting:

1. **Auto-confirm + auto-jury + the strict rubric.** Produces model-asserted approved lessons
   that go straight to `approved/`. Useful on its own only with `visibility: org` and someone
   watching, because there is no window yet.
2. **`approved_held/`, the sweep, `queue` and `veto`.** The window. Inert until (1) exists,
   since nothing writes a held lesson without it.

Shipping (2) first is the safer order if they are split: the window is harmless when nothing
uses it, whereas (1) alone publishes on a jury verdict with no recourse.

## Out of scope

- Fixing the claim-quality defects in ONL-110. The strict rubric raises the bar; it does not
  improve what the transform writes. If ONL-110 goes unfixed, the likely outcome of this design
  is that nothing clears the model floors — which is a safe failure, and measurable.
- Any change to `onlooker sync`, the pool, or `ZLesson` (D5).
- Auto-promotion of *memory* proposals. ADR-001 already covers that with `auto_promote` and this
  design does not touch it.
- Recovering the two lessons already rejected. Both are terminal by design.

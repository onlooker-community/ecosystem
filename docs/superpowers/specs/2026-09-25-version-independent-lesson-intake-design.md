# Version-Independent Lesson Intake — Design

**Status:** Approved, not started.
**Tracked by:** [ONL-107](https://linear.app/onlooker/issue/ONL-107), child of
[ONL-13](https://linear.app/onlooker/issue/ONL-13) (public visibility tier).
**Parent design:** `docs/superpowers/specs/2026-08-09-lesson-transform-design.md`.
That document governs stage five. This one revises two of its parts — the
pre-gate and the validator split — and leaves the rest intact.

---

## The problem

No lesson has ever been approved on this machine. Every candidate that reached
the transform was declined, and 11 of the 15 for the same reason:

```
11  no_versions
 2  schema_invalid
 2  no_resolution
```

Three project keys, `2026-09-19 → 2026-09-25`, with 0 proposals and 0 approved
anywhere. `onlooker sync` has never had anything to push.

The refusals are correct. `plugins/librarian/scripts/lib/librarian-lesson-transform.sh:37-105`
requires `applies_to.scope.kind: "versioned"` with a range per stack entry and
closes every escape hatch: `>=0` is forbidden ("an unbounded lower bound matches
everything and would never expire"), every `versions` key must appear in `stack`,
and "There is no version-independent option. If the claim is not bound to a
version range, refuse with `no_versions`."

The artifacts are commit-derived — `summary` is the commit subject, `detail` the
body — and carry no version field. All 11 declined artifacts are still on disk.
Nine of them do contain version-shaped strings, but they are our own release
numbers, config values and filenames, not stack versions:

```
fix(release): restore the ecosystem version above 0.61.10 — a bare `Release-As: 0.9.0` footer…
feat(echo): measure the judge's spread instead of guessing at it — drift_threshold shipped at 0.05…
feat(api): let a worker stack name a source line — Wrangler writes index.js.map beside the bundle…
```

So the model is asked which third-party stack versions a claim is bound to,
about a lesson learned from our own commits, where the truthful answer is none.

**A version-independent path already exists** — at confirm time, not transform
time. `librarian_lesson_confirm` (`librarian-lesson-review.sh:71-126`) takes a
justification, rewrites scope to `version_independent`, and refuses that branch
at `private` visibility so a jury always checks it. The design intent is a
two-tier trust boundary, stated at `librarian-lesson-validate.sh:144` and
`:164-173`: a **model** may only assert `versioned`; a **human** may assert
`version_independent`.

The gap is reachability. Every gate into the pending queue requires a version
binding:

| stage | gate | internal-practice lesson |
|---|---|---|
| `librarian_lesson_pregate` | needs a version-shaped token | skipped, silently, no LLM call, no record |
| model call | emit `versioned` or refuse | refused `no_versions` |
| `validate_candidate` | `versioned` **only** | never reached |

So `--justification` can only be applied to a lesson that already had a version
binding — that is, never to one that needed it. Of ~1,623 artifacts across three
keys, most are pre-gated out with no record at all; the 15 that reached the model
passed the pre-gate on incidental numbers.

## Decisions

**D1. The pre-gate routes instead of gating.** Its exit status selects a prompt
mode rather than skipping the artifact. Nothing is silently dropped.

**D2. A third scope kind, `unscoped`, legal only while pending.** The two
validators become mirror images, each permitting exactly one kind the other
forbids:

- `librarian_lesson_validate_candidate` (model-side): `versioned` or `unscoped`
- `librarian_lesson_validate_confirmed` (human-side): `versioned` or
  `version_independent`, and **refuses** `unscoped`

`unscoped` can therefore exist in the pending queue and nowhere else. Its only
exit is acquiring a justification, which forces `org` or `public`, which forces a
jury. The invariant is enforced by the validator pair rather than by convention.

**D2a. The vendored subschema is not touched.**
`plugins/librarian/schema/lesson-applies-to.subschema.json` is copied out of the
published lesson contract (`PROVENANCE.json`: `packages/lesson-contract/schema/lesson.schema.json`,
`schema_version` 2) and represents what the *pool* accepts. Adding `unscoped`
there would claim the contract admits a kind it does not. Instead a local,
explicitly-not-vendored `lesson-applies-to-pending.local.schema.json` holds the
pending shape (`versioned | unscoped`).

That keeps "the two mechanisms agree" total on both sides instead of poking a
documented hole in it, and it makes the invariant provable in both directions:

- the vendored pool schema **rejects** `unscoped` — it can never be a pool shape
- the local pending schema **rejects** `version_independent` — a model can never
  mint it

Nothing changes in the onlooker repo or in `ZLesson`: an `unscoped` candidate
never reaches the pool, which is the whole point of D2.

**D3. The model still never asserts version-independence.** In `unscoped` mode it
emits `scope: {kind: "unscoped"}` — a refusal to bind, not a claim that the
lesson holds for every version. The assertion that it holds regardless of version
remains the human's, checked by a jury, exactly as ONL-13 requires.

**D4. No route parameter is threaded into `validate_candidate`.** A
versioned-route model that emitted `unscoped` would park a claim for a human
instead of binding it — degraded, not unsafe, since human-plus-jury still stands.
Threading a mode through a pure validator to close that costs more than it buys.
`librarian-lesson-validate.sh` stays I/O-free and route-blind.

**D5. Over the cap, an artifact is skipped, not declined.** A decline is terminal
(`librarian_lesson_seen` reads `declined.jsonl`), so recording one for a
cost-control skip would destroy the candidate permanently. Skipping follows the
principle already stated in `librarian-classify-worker.sh`: untransformed
artifacts are reconsidered on a later session, so the cost of stopping early is a
delay.

**D6. `reconsider` rewrites `declined.jsonl`.** Without removing the line, a
replayed artifact is skipped as seen. The rewrite is atomic, and an artifact whose
file is gone stays declined.

**D7. Confirming an `unscoped` candidate without a justification is refused with
a message**, mirroring the private+justification refusal at
`librarian-lesson-review.sh:90` rather than silently doing something else.

## Architecture

Stage five's funnel, with the change in the middle:

```
durable classified artifact
  → librarian_lesson_seen            (unchanged: terminal declines + proposals)
  → librarian_lesson_pregate         (CHANGED: routes, does not skip)
      ├─ version token  → versioned prompt → bind a range, or refuse no_versions
      └─ no token       → unscoped prompt  → scope {kind: unscoped}, or refuse no_resolution
  → librarian_lesson_validate_candidate   (CHANGED: versioned | unscoped)
  → proposal, status pending
  → human: librarian_cli lessons confirm <id> <org|public> --justification TEXT
  → librarian_lesson_validate_confirmed   (CHANGED: refuses unscoped)
  → jury → promote → approved → syncable
```

`librarian_lesson_transform_one` (`librarian-lesson-transform.sh:231`) keeps its
shape and its string-result protocol. One new result value,
`skipped:unscoped_cap`. A parked candidate returns `proposed:<id>` like any other
— it *is* a proposal — so `LESSON_PROPOSED` and the `scan.complete` counts need no
change and a parked candidate is never miscounted as a decline.

### Prompt modes

`librarian_lesson_build_prompt` takes a mode. The `versioned` mode is today's
prompt verbatim, including the `no_versions` refusal — a token was found, so
binding is the right ask. The `unscoped` mode keeps the same output contract and
replaces the version-range section: emit `scope: {kind: "unscoped"}` when the
claim is not bound to a stack version range, with `no_resolution` as the only
remaining refusal. `no_versions` is unreachable in `unscoped` mode by construction.

`applies_to.stack` stays required in both modes. It sits outside `scope` in the
structural clause, and `version_independent` scope carries only `kind` and
`justification`, so a parked candidate is the same object as today's with only
the scope branch left open.

### Surfacing a parked candidate

A parked candidate is only useful if the person walking the queue knows it needs a
justification before it can go anywhere. Without that, the walk offers `private`,
confirm refuses it (D7), and the user meets a dead end with no explanation.

So `librarian_cli lessons list` and `lessons show` mark a candidate whose scope is
`unscoped`, and the lesson walkthrough in `plugins/librarian/skills/librarian/SKILL.md`
gains one branch: for a parked candidate, ask for a justification and offer only
`org` or `public`, naming why `private` is not available for it. The existing
`--justification` semantics are unchanged — this is the walk learning when they
are mandatory rather than optional.

### Cost control

`.librarian.lesson_transform.unscoped_per_scan`, default **3**, counted in the
worker loop at `librarian-classify-worker.sh:479` alongside the existing 600s
`total_budget_ms`. The versioned route is uncapped — its volume is unchanged from
today. Only the newly reachable route is bounded, so this change cannot make a
scan cost more than three extra model calls.

### Reconsider

`librarian_cli lessons reconsider [--limit N]`:

1. Read `declined.jsonl`, select records with `reason == "no_versions"`.
2. Reload each artifact from archivist storage by `artifact_id`. Missing file →
   leave the decline in place, report it.
3. Atomically rewrite `declined.jsonl` without the selected lines.
4. Route each recovered artifact through the `unscoped` path, under the same cap.

`--limit` bounds a run; without it, the cap does. The command is idempotent in
the sense that matters: a record it has already removed cannot be selected twice.

## Failure taxonomy

| outcome | meaning | terminal? |
|---|---|---|
| `skipped:seen` | already handled | n/a |
| `skipped:unscoped_cap` | cost control; comes back next scan | no |
| `declined:no_resolution` | records a problem, not a fix — not a lesson | yes |
| `declined:no_versions` | versioned route only: token found, binding impossible | yes, recoverable via `reconsider` |
| `declined:schema_invalid` | model output failed the validator | yes |
| `declined:transform_invalid` | not JSON, or refusal with an unknown reason | yes |
| `unavailable` | infrastructure; artifact untouched | no |

`skipped:pregate` is retired: nothing is *permanently* dropped without a record.
The one silent outcome left is `skipped:unscoped_cap`, which writes nothing by
design — that is precisely what lets the artifact come back.

## Idempotency

Unchanged for the versioned route. For the unscoped route: a parked candidate is
a proposal, so `librarian_lesson_seen` covers it by the existing
proposals-are-the-dedup-source rule. A capped artifact writes nothing, which is
what makes it safe to reconsider. `reconsider` is the only operation that removes
a terminal record, and it removes only `no_versions`.

## Testing

bats, per `test/bats/librarian-lesson-transform.bats` conventions and the shared
helpers in `test/helpers/setup.bash`:

1. An artifact with no version token produces a parked candidate with
   `scope.kind == "unscoped"`, and no `no_versions` decline is written.
2. An artifact with a version token still takes the versioned route and can
   still decline `no_versions` — today's behavior is unchanged.
3. `validate_confirmed` refuses `unscoped`.
4. `confirm` without `--justification` on a parked candidate is refused, with the
   message naming what is required.
5. `confirm <id> org --justification TEXT` rewrites scope to
   `version_independent` with no stale `versions` key left behind (the key-set
   rule at `librarian-lesson-review.sh:168`).
6. The cap stops the unscoped route at N and writes **no** decline record for the
   artifacts it skipped.
7. `reconsider` replays `no_versions` records only, drops those lines, and leaves
   `no_resolution` and `schema_invalid` records in place.
8. `lessons list` and `lessons show` mark a parked candidate, so the walk can
   tell it apart from a version-bound one.
9. `validate_candidate` and the new local pending schema agree on `unscoped`,
   and the **vendored** subschema rejects it — the pair of assertions that proves
   it can never be a pool shape. Asserted separately, since the two mechanisms
   have been proven able to disagree.
10. `check-lesson-schema-drift.mjs` still passes: the `schema_version` pin and
    both vendored files are untouched.

## Events

**No new event ships with this change.** A parked candidate is written as a
proposal and is therefore already covered by `librarian.candidate.proposed` and
the `librarian.scan.complete` counts.

A dedicated `librarian.lesson.parked` was considered and cut. `@onlooker-community/schema`
is an external dependency (`^2.22.0`), no `librarian.lesson.*` type exists in it
today, and CLAUDE.md requires registration before emission — so the type would
need a PR to the schema repo, a release, and a bump here before it could be
emitted without failing `npm run test:bus`. That is a cross-repo dependency this
change does not need, and the gap it would fill is [ONL-7](https://linear.app/onlooker/issue/ONL-7)'s
(librarian emits nothing when it writes a lesson), not this one's.

If a lesson-write event lands under ONL-7, distinguishing a parked write from a
version-bound one belongs in that event's payload rather than in a second type.

## Boundary changes to sibling issues

- **ONL-13** (parent): this implements the reachability half of the tier
  question. It does not specify the public tier's read path, moderation, or
  unanimity rule — those remain ONL-13's.
- **ONL-7**: librarian still emits nothing when it writes a *lesson*, so doctor
  still has no write signal for it. This change does not close that, and
  deliberately adds no event of its own — see Events above.
- **ONL-6**: whether archivist's PreCompact-only trigger is the right artifact
  source is untouched. This change widens what a delivered artifact can become,
  not what gets delivered.

## Out of scope

- Supplying *versions* at confirm time for a parked claim the model could not
  read. YAGNI until a real case wants it; the justification path covers the
  motivating corpus.
- Retiring the `no_versions` reason. It stays correct on the versioned route.
- Any change to the jury, the rubric, promotion, or sync.

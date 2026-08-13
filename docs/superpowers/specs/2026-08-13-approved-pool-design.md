# Approved Pool and Declined Ledger — Design

**Status:** Approved, not started.
**Tracked by:** `ecosystem-4z8.4`, the last open child of epic `ecosystem-4z8`.
**Upstream:** the jury (`4z8.3`, PR #142) and `author_key` derivation (`4z8.5`, PR #144).

---

## What this stage is

The terminal state. A judged proposal becomes either a pool entry awaiting sync
or a row in the declined ledger, and the pipeline is done with it.

Nothing crosses the network. The sync service that drains the approved pool
does not exist yet.

## The verb

`librarian_lesson_promote <key> <lesson_id>`.

| Proposal status | Result |
|---|---|
| `approved` | a pool entry at `lessons/approved/<ulid>.json` |
| `rejected` | a row appended to `lessons/declined.jsonl` |
| `confirmed` | refused — judged nothing yet |
| `pending`, `passed` | refused, naming the status |
| already promoted | no-op success |

The `lessons judge` CLI verb calls it immediately after recording a verdict, so
the ordinary path stays one command. It is also runnable standalone, which is
not redundancy: **promotion fails for reasons judging does not.** A malformed
`user_secret`, an absent `node`, a full disk — none of those are the jury's
problem, and all of them leave a lesson correctly judged and not yet promoted.
Standalone promote is how that gets reconciled.

### Already promoted is a no-op, not an error

Same precedent as `unconfirm` on a `pending` lesson. It makes a reconcile loop
trivially safe to run over everything. "The same artifact cannot be promoted
twice" is still enforced — there is no second write and `promoted_at` does not
change — it simply is not an error to ask.

## The pool entry

`ZLesson`-shaped. Its exact key set, which the design must match because
`ZLesson` is a `z.strictObject` — an extra key fails ingest as surely as a
missing one:

```
applies_to  author_key  claim  consensus  evidence  id  promoted_at
rationale   schema_version  source  status  superseded_by  visibility
```

Mapped from the proposal:

| Field | Source |
|---|---|
| `id` | the proposal's ULID — the lesson keeps one identity end to end |
| `schema_version` | literal `2` |
| `claim`, `rationale`, `evidence`, `applies_to` | the candidate, unchanged |
| `visibility` | the proposal |
| `source` | `private` → **`local`**, `org` → `org`, `public` → `public` |
| `consensus` | `{judges: (verdict.judges \| length), agreed: (count where .passed), decided_at: judged_at}` |
| `status` | `active` |
| `superseded_by` | `null` |
| `author_key` | `librarian_author_key <visibility>` |
| `promoted_at` | now, ISO-8601 UTC |

### The `source` mapping is a real mismatch, not a rename

`ZSource` is `z.enum(["local", "org", "public"])` while visibility is
`private | org | public`. Nothing in the contract or the pipeline docs states
how they line up. `private` → `local` is the only coherent reading — the tier
that never leaves the machine maps to the source that means "not from anywhere
else" — but it is written down here because an implementer would otherwise
either guess or emit `private` and fail ingest.

### A private pool entry is deliberately not ingest-valid

`ZConsensus` requires `judges: z.number().int().min(1)`. A `private` lesson
runs no jury at all, so its `consensus.judges` is `0` and it **cannot validate
against `ZLesson`**.

This is accepted rather than worked around. The contract's own comment says
validation happens at ingest, and a private lesson never syncs — so it never
reaches the validator. The pool means "everything approved locally"; the sync
service filters to `org` and `public`.

The alternative was synthesizing `judges: 1, agreed: 1` so every entry
validates uniformly. Rejected: it fabricates a jury that never sat, and
anything later reading `consensus` to mean "this was judged" would be quietly
wrong about exactly the tier where nothing was.

**The consequence to state plainly:** there can be no blanket "validate the
pool" check. A validator must filter to `org` and `public` first, and this
spec is where that requirement is recorded.

### The pool write is atomic

Temp file, then `mv`. `ecosystem-a3b` is open against the three existing
non-atomic write sites in this plugin (`confirm`, `pass`, `unconfirm`, all
`printf > path`, which truncates before writing). This is a new write site;
adding a fourth instance of a known bug is a choice, not an inheritance.

Fixing the existing three is `a3b`'s job and stays out of this branch.

## The declined ledger

Jury rejections append through the existing
`librarian_lesson_append_declined <key> <artifact_id> <reason> [detail]`,
which already produces `{artifact_id, reason, detail, declined_at}`.

The `reason` is the gate's own — `below_threshold`, `jury_not_unanimous`,
`jury_not_majority`. The pool entry's `consensus` keeps only counts, so for a
rejected lesson this ledger is the only place the per-judge scores and feedback
survive, and that is the rubric-tuning signal.

**The verdict needs its own key, not `detail`.** The existing function builds
`detail` with `jq --arg`, which makes it a *string* — passing the verdict there
would store serialized JSON inside a JSON field, and every consumer would have
to `fromjson` it before reading a score. Instead, extend
`librarian_lesson_append_declined` with an optional fifth argument emitted via
`--argjson` into its own `verdict` key, so it lands as a real nested object.

Rows written by stage 5 simply lack that key, which is correct: a transform
failure has no verdict. `librarian_lesson_seen` reads only `.artifact_id`, so
the added key does not touch it.

### Why jury rejections belong in this file rather than a third one

`4z8.2` drew the line between `declined.jsonl` and `passed.jsonl` at **machine
verdict versus human intent** — mixing "I didn't want to share this" into the
same file as "the model emitted malformed JSON" would corrupt the signal the
file exists to carry.

A jury rejection is a machine quality judgment. By that line it belongs in
`declined.jsonl` alongside the transform's own drops, distinguished by `reason`.

**This does *not* leave `librarian_lesson_seen` untouched, as shipped.** It
already reads `declined.jsonl` and `proposals/`, and also scans `approved/` —
but that scan can never match a promoted entry, because `ZLesson` is a
`strictObject` with no `artifact_id` field (see the pool entry's key set,
above). Dedup for a promoted lesson works today only because `proposals/` is
never pruned, standing in for coverage the pool entry cannot provide. That gap
is tracked as `ecosystem-d0m`; this stage does not close it.

## Ordering, and why it is load-bearing

The terminal record lands **first**. Only then is `promoted_at` stamped on the
proposal.

Reversed, a stamp followed by a failed write would leave the lesson permanently
unpromotable — marked done, present nowhere, and invisible to any reconcile
that keys on the absence of the stamp. In this order a failure between the two
steps means a re-run finds the pool entry already present, skips rewriting it,
and completes the stamp.

Every failure path before the terminal record lands writes **nothing** and
returns non-zero with a reason on stderr. One failure path is the exception by
design: the terminal record can land and then the stamp itself fail (a
read-only `proposals/`, an interrupted process). There the record is on disk,
the proposal stays `approved` without `promoted_at`, and the stderr message
says so explicitly — naming the standalone re-run — so this state is never
mistaken for "nothing written."

## The proposal file survives

It stays in `proposals/` carrying its terminal status, `judged_at`, `verdict`,
and now `promoted_at`.

Two reasons. The `promoted_at` stamp is what makes promote-twice detectable at
all. And the pool entry carries only `consensus` counts, so for an **approved**
lesson the per-judge scores and feedback exist nowhere else — deleting the
proposal would discard the rubric-tuning signal for every lesson that passed,
keeping it only for those that failed.

`proposals/` therefore grows without bound. Accepted: `lessons list` already
filters to `pending`, and `librarian_lesson_seen` scanning a larger directory is
the same work it already does.

## Events

None. `@onlooker-community/schema` 2.11.0 registers only
`meridian.lesson.curated` — no `librarian.lesson.*` at all — and the runtime
emitter exits 1 on an unknown `event_type`.

This is the fourth consecutive stage running silent for the same reason. When
the schema package publishes the types, one follow-up wires all four together.

## Testing

bats, isolated temp home, per the repo's `writing-tests` skill — single-bracket
assertions or `|| return 1` on non-final ones, and every new assertion broken
once to confirm it discriminates.

- **The pool entry's key set exactly equals `ZLesson`'s.** `ZLesson` is a
  `strictObject`, so an extra key fails ingest as surely as a missing one, and
  this is checkable without running zod: compare `jq 'keys_unsorted | sort'`
  against the literal list above.
- `private` yields `consensus.judges: 0` and `source: local`; `org` and
  `public` yield matching `source` and `judges`/`agreed` derived from the
  verdict's array.
- `agreed <= judges` — the contract's own ingest rule, which its schema
  deliberately cannot express.
- A `rejected` proposal writes a `declined.jsonl` row carrying the gate's reason
  and the verdict, **and no pool entry**. The row's `verdict` is a nested
  object, not a string — assert `jq '.verdict.judges | length'` rather than a
  substring match, since a `--arg`/`--argjson` mistake produces a row that looks
  right to the eye and is unusable to a consumer.
- A stage-5 style decline (transform failure, no verdict) still writes cleanly
  and simply lacks the `verdict` key.
- `confirmed`, `pending`, and `passed` are each refused, naming the status.
- Promoting twice leaves exactly one pool entry with an unchanged
  `promoted_at`.
- **A failing `author_key` leaves nothing written and the proposal still
  `approved` without `promoted_at`** — the reconcile property, and the one most
  worth pinning.
- `librarian_lesson_seen` reports the artifact handled after the declined
  path. There is deliberately no approved-path equivalent: a promoted entry
  carries no `artifact_id`, so that assertion would pass or fail on whether
  `proposals/` still holds the file, never on anything promote itself wrote —
  see `ecosystem-d0m`.
- **Promotion spends nothing** — asserted with a `claude` stub on `PATH` that
  fails loudly if invoked, the technique that already proved stages 5, 6, and 7.

## Out of scope

Any sync. Retraction and supersession — `status` is always `active` and
`superseded_by` always `null`, because there is no consumer for either and
inventing one repeats the mistake `si6` avoided. Events, per above. Consuming
the declined ledger for rubric tuning. And fixing `ecosystem-a3b`'s three
existing non-atomic writes.

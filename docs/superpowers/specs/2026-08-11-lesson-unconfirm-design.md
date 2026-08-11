# Lesson Unconfirm — Design

**Status:** Approved, not started.
**Tracked by:** `ecosystem-si6`, wired as a blocker on `ecosystem-4z8.3`.
**Upstream:** `docs/superpowers/specs/2026-08-10-lesson-confirmation-design.md`
(shipped in PR #137).

---

## What this is

A way back from a confirmed lesson, before the jury has seen it.

`confirmed` is currently terminal. `librarian_lesson_confirm` treats a repeat as
idempotent only when visibility and candidate match exactly and refuses anything
else; `librarian_lesson_pass` refuses a confirmed lesson outright; nothing else
writes the proposal file. So a human who confirms at `public` meaning `private`
has no path back — and that is the direction most worth correcting, since
`public` is the tier that leaves the machine and draws the disclosure lens.

Those guards are not the problem and should not be loosened. They are what keeps
`lessons/passed.jsonl` from contradicting the proposal it describes, and they
exist because pass-then-confirm once left the ledger asserting a human had
declined something the proposal said was confirmed and bound for the jury. The
guards closed the write path correctly. They just left no recovery path.

## Why a verb rather than a relaxed guard

The alternative was letting `confirm` overwrite a prior confirm with a different
visibility. Rejected on two grounds.

It would delete the guard that makes repeats safe — the same guard added in
response to a real contradiction bug. And it would make a typo'd repeat silently
change visibility on the verb that commits a lesson toward leaving the machine.

An explicit "I take that back" matches how this design has treated every other
irreversibility: make the consequential thing deliberate rather than incidental.

## The state rule

`librarian_lesson_unconfirm <key> <lesson_id>`, surfaced as
`librarian_cli lessons unconfirm <id> [cwd]`.

| Current status | Behavior |
|---|---|
| `confirmed` | → `pending`; clear `visibility` and `confirmed_at`; restore the candidate snapshot |
| `pending` | no-op success — already there |
| `passed` | refuse |
| anything else | refuse, naming the status |

`pending` as an idempotent no-op mirrors how `pass` treats an already-passed
lesson, so repeat invocations are safe.

Refusing `passed` keeps the ledger authoritative. Silently moving a passed
lesson back to `pending` would leave `passed.jsonl` asserting a decision the
proposal contradicts — precisely the bug the status guards were added for.
Passing is a different decision from confirming, and it has its own durable
record; undoing it is not this verb's job.

## The candidate snapshot

`confirm` writes four things: `status`, `visibility`, `confirmed_at`, and
`.candidate`. That last one is why returning to `pending` is not enough on its
own — a `--justification` rewrites the candidate's scope to
`version_independent`, and nothing records what the transform originally
inferred.

Without a snapshot, unconfirming a justification-confirm leaves the proposal
carrying `version_independent` scope with no route back to its `versioned`
form. The confirmation stage's own guard would then correctly refuse it at
`private` — so the user escapes one dead end into another, for exactly the
mistake most worth undoing.

**`confirm` stores the pre-rewrite candidate as `candidate_before_confirm`, and
only when it actually rewrites scope.** `unconfirm` restores it and deletes the
field.

Deleting it is load-bearing. A stale snapshot left on a `pending` proposal is
indistinguishable from a live one at the next confirm, and would silently revert
a later legitimate rewrite. Absence of the field means the candidate was never
mutated and there is nothing to restore — which is the common case, since a
plain confirm does not touch it.

## Surfaces

`librarian_cli lessons unconfirm <id> [cwd]`, carrying the same `--*` flag
rejection the other lesson verbs have. An unrecognized flag must not be absorbed
as a `cwd` candidate; that hazard is already fixed twice in this pipeline and
the contract should be consistent across the verb set.

The `/librarian lessons` skill gains it in the verb table and in the walk,
described as taking back a confirmation before the jury sees it.

## Events

None, consistent with the rest of this stage. `librarian.lesson.*` is
unregistered in `@onlooker-community/schema` 2.11.0 and the emitter exits 1 on
an unknown `event_type`. The next stage reads proposal files, not the bus.

## The seam to the jury

This is a promise to code that does not exist yet, so state it plainly.

`unconfirm` proceeds **only** from `confirmed`. Every other status falls to the
catch-all and is refused with the status named. When `4z8.3` introduces a status
of its own — `judging`, `judged`, whatever it picks — `unconfirm` refuses it
automatically, with no change here and no coordination between the two stages.

That is what "must not preclude a jury-consumption state" means in practice: the
existing convention of refusing unrecognized statuses loudly already handles a
consumer that has not been written.

**This design deliberately does not add a `judging` status now.** Inventing a
state machine for an unwritten consumer produces a status nothing sets and every
verb must handle. `4z8.3` owns that decision; this verb is forward-safe without
it.

## Testing

bats, isolated temp home, per the repo's `writing-tests` skill — single-bracket
assertions or `|| return 1` on non-final ones, and every new assertion broken
once to confirm it discriminates.

- **Round trip.** Confirm at `public` with a justification, then unconfirm: the
  proposal is byte-identical to its pre-confirm state, scope back to
  `versioned`, and no `candidate_before_confirm` left behind.
- Unconfirm from `pending` is a no-op success.
- Unconfirm from `passed` is refused, and `passed.jsonl` is untouched.
- An unrecognized status is refused with the status named.
- **After unconfirm, a fresh confirm at a different visibility succeeds** — the
  user story this verb exists for.
- Unconfirm invokes no model, asserted with a `claude` stub that fails loudly if
  called.
- A plain confirm (no justification) writes no snapshot, and unconfirming it
  still returns the proposal to `pending` cleanly.

## Out of scope

The jury, the approved pool, `author_key`, and any sync. Undoing a `pass` is
also out of scope — that decision has its own ledger and its own reasoning, and
conflating the two undos is how the ledger starts disagreeing with the proposal
again.

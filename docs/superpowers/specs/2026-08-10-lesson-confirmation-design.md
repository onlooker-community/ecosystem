# Lesson Confirmation — Design

**Status:** Approved, not started.
**Tracked by:** `ecosystem-4z8.2`, under epic `ecosystem-4z8`.
**Upstream:** `docs/superpowers/specs/2026-08-09-lesson-transform-design.md` (stage 5,
shipped in `librarian-v0.7.1`).
**Parent design:** `docs/superpowers/specs/2026-08-08-promotion-pipeline-design.md` in the
[onlooker](https://github.com/onlooker-community/onlooker) repo, Sections 2–3.

---

## What this stage is

The human picks which lesson candidates go to the jury, and their intended
visibility, before any Opus tokens are spent.

This splits the pipeline's two filters along their natural lines. The human
judges **intent** — "do I want to share anything about this?" — which is cheap
and which only they can do. The jury judges **quality**, which is expensive and
which only it can do. Cost then scales with intent rather than artifact volume.

It also keeps promotion propose-only, consistent with librarian's ADR-001.

## Where it lives

`/librarian lessons`, dispatched through a nested `librarian_cli lessons <verb>`.

Librarian already has a review surface for memory promotions: a SessionStart
surfacer that injects a one-line pointer, a `/librarian` skill that walks the
queue one entry at a time, and a CLI with `list` / `show` / `accept` / `reject`
/ `defer`. Lessons reuse that plumbing but keep a separate queue, separate
verbs, and a separate walk.

Sharing the *machinery* while separating the *surface* is the point. The two
decisions look alike and are not: accepting a memory writes a file on your
machine, while confirming a lesson commits it toward being shared beyond your
machine, irreversibly once synced. ADR-001's argument — that a wrong promotion
is silent, slow to detect, and keeps acting on you afterward — applies harder
here, not softer. A lesson confirmation should never sit one keystroke away
from a memory accept in the same list.

The verb sets differ anyway. Memory review is a binary plus a punt. Every
lesson confirmation carries a third axis, visibility, that has no counterpart
on the memory side.

### Verbs

| Command | Effect |
|---|---|
| `librarian_cli lessons list` | pending lessons, one row each |
| `librarian_cli lessons show <id>` | full candidate for one proposal |
| `librarian_cli lessons confirm <id> --visibility <v>` | `status: "confirmed"`, records `visibility` |
| `librarian_cli lessons pass <id> [reason]` | `status: "passed"`, appends to `passed.jsonl` |
| `librarian_cli lessons defer <id>` | no-op on state; leaves it `pending` |
| `librarian_cli lessons status` | one-line counts |

`confirm` also accepts `--version-independent <justification>`, which rewrites
`applies_to.scope` to that branch and is subject to constraint 2 below.

The walk shows, per candidate: `claim`, `rationale`, `evidence.resolution`, the
inferred `applies_to.stack` and `scope.versions`, and the source `artifact_id`.
Resolution is shown because it is the field that distinguishes a lesson from a
warning, and it is the one a human is best placed to sanity-check.

## State model

All three states live on the proposal file the transform already writes at
`~/.onlooker/librarian/<project-key>/lessons/proposals/<ulid>.json`.

| `status` | Meaning | Written by |
|---|---|---|
| `pending` | transform wrote it; nobody has looked | stage 5 (ships today) |
| `confirmed` + `visibility` | human wants it shared; awaiting the jury | this stage |
| `passed` | human declined to share it | this stage |

The file already carries `status: "pending"` and nothing reads it yet, so this
stage gives an existing field its purpose rather than introducing a parallel
one.

**A passed candidate keeps its file.** `librarian_lesson_seen` scans
`proposals/` by `artifact_id`, so leaving the file in place is what stops a
declined artifact being re-proposed on the next scan. Deleting it would make
the pipeline re-transform and re-ask every session, re-paying Haiku each time
for an answer the human already gave.

### Two ledgers, deliberately not one

```
lessons/proposals/<ulid>.json   pending | confirmed | passed
lessons/declined.jsonl          machine verdicts   (stage 5)
lessons/passed.jsonl            human intent       (this stage)
```

`declined.jsonl` exists to make expensive drops auditable and to produce the
data that tunes the rubric later. A human declining to share is a statement
about intent, not about quality. Mixing "I didn't want to share this" into the
same file as "the model emitted malformed JSON" would corrupt exactly the
signal that file exists to carry.

Keeping them apart also makes each readable on its own: what does the model get
wrong, versus what do I not want to share.

`passed.jsonl` records `artifact_id`, `lesson_id`, `passed_at`, and an optional
free-text reason. Append-only, like its sibling.

## The three constraints

These are the acceptance criteria expressed as properties of the code rather
than as promises.

**1. `confirm` requires an explicit visibility.** There is no default and no
bare `confirm`. A candidate cannot reach `confirmed` without someone naming
`private`, `org`, or `public`.

**2. `version_independent` forces `org` or `public`.** Combining it with
`private` is refused, with the reason stated.

The transform can only emit `versioned` scope — that is what stops it minting
lessons that never expire. This stage hands that branch to a human, who has the
context to write a real justification. But private lessons run no jury, so a
private `version_independent` claim would reach the pool with nothing checking
it: the same hole, reached by a different door, with a person instead of Haiku
writing the unchecked claim.

Requiring org or public means the claim gets judged. `scope_accuracy` is the
criterion that asks whether the justification is actually true, and the
disclosure lens applies on top at the public tier. The schema stops the
accident; the jury stops the lazy excuse; this constraint is what guarantees
the jury is present to do so.

**3. This stage never calls a model.** No Haiku, no Opus, no network. That is
what makes "no tokens spent on unselected candidates" checkable rather than
merely intended.

## Two validators, on purpose

`librarian_lesson_validate_candidate` hard-requires
`.applies_to.scope.kind == "versioned"`. A human-converted `version_independent`
candidate therefore fails it.

This stage gets its own: `librarian_lesson_validate_confirmed`, which permits
either branch, requires a non-empty `justification` when the branch is
`version_independent`, and otherwise enforces exactly what the transform's
validator enforces — including the provenance rules and the version-range
pattern.

The two are not redundant and the difference is not stylistic. They encode
different trust: one bounds what a model may assert unsupervised, the other
bounds what a human may assert *and a jury will then check*. The versioned-only
rule stays on the transform path, where nothing downstream would catch a bad
claim.

State this in the code. A future reader who finds two validators and assumes
one is dead will delete the wrong one.

## Surfacing

The SessionStart surfacer gains a second count: a distinct one-line pointer when
lesson proposals are pending, alongside the existing memory-proposal line.

Bodies stay out of SessionStart. That follows the surfacer's own stated reason —
session-start context is precious, and a queue of unreviewed entries is not
where it should go. The walk is where candidates get read.

## Events

Deferred, for the same reason stage 5 deferred its own.

`librarian.lesson.confirmed` and `librarian.lesson.passed` would be as
unregistered in `@onlooker-community/schema` as `.proposed` and `.declined`
still are — verified against 2.11.0, which carries no `librarian.lesson.*`
types at all. With a validator resolvable, the emitter rejects an unknown
`event_type` and exits 1.

Nothing is lost by waiting: `4z8.3` reads the proposal files, not the bus. When
the schema package publishes all four types, one follow-up wires them together.

## Testing

bats, isolated temp home, per the repo's `writing-tests` skill — including its
rule that non-final `[[ ]]` assertions need `|| return 1`, and its habit of
breaking each new assertion once to confirm it discriminates.

The cases that matter are the three constraints, because each is a guarantee:

- `confirm` with no visibility is refused and leaves `status: "pending"`
- `version_independent` + `private` is refused, with the reason
- confirming invokes no model — asserted with a `claude` stub on `PATH` that
  fails loudly if called, the same technique that proved the transform's
  `unavailable` path

Plus:

- a passed candidate keeps its file, and `librarian_lesson_seen` still reports
  its artifact handled
- this stage never writes to `declined.jsonl`
- a confirmed candidate carries both `status: "confirmed"` and its `visibility`
- `librarian_lesson_validate_confirmed` accepts a well-formed
  `version_independent` candidate and rejects one whose justification is empty,
  while still rejecting everything the transform's validator rejects

## Boundary to the next stage

`4z8.3` selects proposals where `status == "confirmed"` and reads `visibility`
from the same file to choose its gate: no jury for `private`, the
`lesson-promotion` rubric for `org`, rubric plus disclosure lens for `public`.

Nothing else crosses between the stages.

## Out of scope

The jury itself, the approved pool, `author_key` derivation, and any sync. This
stage ends when a candidate is marked confirmed.

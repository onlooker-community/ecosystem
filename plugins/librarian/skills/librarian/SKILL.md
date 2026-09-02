---
name: librarian
description: Review the librarian's pending memory promotion proposals and lesson candidates queued from past sessions. Walk pending entries with the user one at a time, surfacing provenance and conflict state, and route each to accept (writes the typed memory file and updates MEMORY.md), reject (writes a body-hash tombstone so the same content won't re-propose), or defer (leave in the queue). Lesson candidates route separately to confirm (with a visibility), pass, or defer, with unconfirm to take back a confirmation before the jury sees it. Use when the user types `/librarian`, `/librarian review`, `/librarian triage`, `/librarian status`, `/librarian list`, `/librarian lessons`, `/librarian lessons review`, or `/librarian lessons judge`, or asks to review librarian proposals or lesson candidates.
---

# Librarian: Promotion Queue Review

You are operating the **Librarian** review surface — the user-facing control for promoting per-session artifacts (decisions, dead-ends, open questions captured by Archivist) into the user's durable typed memory store.

Auto-promotion is intentionally off. Librarian queues proposals; the user (with your help) confirms each one. Every accept writes a real file into `~/.claude/projects/<encoded>/memory/`, so every accept matters.

## Parse the request

Read the user's argument after `/librarian`:

- no argument, or `review`, `triage`, `walk` → **walk the queue** (default)
- `list` → print the pending table and stop
- `status` → print one-line counts and stop
- a proposal id (starts with a ULID-shaped string) → jump straight to **show** for that id
- `lessons`, `lessons review` → **walk the lesson queue** (see below)
- `lessons list` / `lessons status` → print and stop (`lessons list --confirmed` lists confirmed lessons instead of pending ones)
- `lessons judge` → **run the jury over confirmed candidates** (see below)

If the user passes a free-form intent ("clear out the queue", "what's pending?"), map it to `review` or `list` as appropriate.

## Run the control surface

Source the plugin helpers and invoke `librarian_cli`. Run this in a single bash call when you need state:

```bash
set -uo pipefail
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-config.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-project-key.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-storage.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-emit.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-storage.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-validate.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-review.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-rubric.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-judge.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-author-key.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-lesson-promote.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-cli.sh"

# action is one of: list | show <id> | accept <id> | reject <id> [reason] | defer <id> | status
# or: lessons <list [--confirmed]|show <id>|confirm <id> <visibility> [--justification TEXT]|pass <id> [reason]|unconfirm <id>|defer <id>|status>
librarian_cli "<action>" "<args...>"
```

`librarian_cli` resolves the project key from the current working directory automatically and routes writes to the typed memory store under `${CLAUDE_CONFIG_DIR}/projects/${CLAUDE_PROJECT_ENCODED}/memory/` (falling back to `$HOME/.claude` when Claude Code exports no config dir) (deriving the encoded path from `cwd` when the env var is unset).

## The review walkthrough

For `review` (the default), loop:

1. Call `librarian_cli list`. If the output says `No pending proposals.`, tell the user the queue is clear and stop.
2. Take the first pending id from the table. Call `librarian_cli show <id>` to render the proposal's provenance, classifier confidence, conflict state, and full body.
3. Present the proposal to the user in plain English. Lead with the title and the proposed memory **type** (user / feedback / project / reference) — those determine where it lands in the user's memory store. If the **conflict_state** is anything other than `none` (typically `near_duplicate` or `contradicts_existing`), call this out explicitly and recommend a careful read before accepting.
4. Ask the user how to route it: **accept**, **reject** (optionally with a reason), **defer** (revisit next session), or **skip** (move on without recording a decision).
5. Route the answer:
   - **accept** → `librarian_cli accept <id>`. Confirm the resulting path Librarian printed and move to the next proposal.
   - **reject** → `librarian_cli reject <id> "<reason>"`. The reason is optional but valuable — it's recorded on the proposal and the tombstone is keyed on body hash so the same content won't be re-proposed.
   - **defer** → `librarian_cli defer <id>`. The proposal stays pending; mention it'll resurface next session.
   - **skip** → don't call the CLI for this id, move to the next proposal.
6. After each routed decision, fetch the next pending id (the previous one will have flipped status, so `list` reorders naturally) and repeat. When `list` returns no rows, finish with `librarian_cli status` so the user sees the final counts.

For `list` and `status`, just call `librarian_cli <action>` once and render the output.

## The lesson walkthrough

Lesson candidates are a separate queue from memory proposals — confirming one is a step toward publishing beyond this machine, not writing a local file, so it gets its own walk rather than folding into the loop above.

For `lessons` / `lessons review` (default for the `lessons` route), loop:

1. Call `librarian_cli lessons list`. If the output says `No pending lessons.`, tell the user the queue is clear and stop.
2. Take the first pending id. Call `librarian_cli lessons show <id>` to render it.
3. Present the candidate to the user in plain English, showing: `claim`, `rationale`, `evidence.resolution`, `applies_to.stack`, `scope.versions` (or the scope kind if unversioned), and the source artifact id.
4. Ask the user how to route it: **confirm** (with a visibility), **pass** (optionally with a reason), or **defer**.
5. Route the answer:
   - **confirm** → `librarian_cli lessons confirm <id> <visibility> [--justification TEXT]`. Confirming **requires** a visibility (`private`, `org`, or `public`) — never call confirm without one. `--justification` rewrites the scope to `version_independent` and requires `org` or `public` visibility: a `private` lesson runs no jury, so its justification would go unchecked. If the user wants version-independence at `private`, tell them why it's refused rather than silently dropping the justification.
   - **pass** → `librarian_cli lessons pass <id> "<reason>"`. The reason is optional.
   - **defer** → `librarian_cli lessons defer <id>`. The candidate stays pending; mention it'll resurface next session.
6. After each routed decision, fetch the next pending id and repeat. When `list` returns no rows, finish with `librarian_cli lessons status` so the user sees the final count.

A confirm made at the wrong visibility isn't stuck that way — `librarian_cli lessons unconfirm <id>` takes it back, returning the lesson to pending so the user can confirm it again at the right visibility. It only works on a `confirmed` lesson: a `passed` lesson stays passed, because that decision already has its own record and unconfirm won't touch it.

Finding the lesson is its own step, because `lessons list` shows only the pending queue and a confirmed lesson is by definition not in it. The user regretting a confirm is usually back in a later session with the claim in mind and no id, so start from `librarian_cli lessons list --confirmed`, which prints the same `<id>  <claim>` rows for everything confirmed and not yet judged. Then `librarian_cli lessons show <id>` — its `visibility` line is what tells you which tier the lesson currently sits at, and whether unconfirming is what the user actually wants.

For `lessons list`, `lessons list --confirmed`, and `lessons status`, just call `librarian_cli lessons <action>` once and render the output.

For `lessons judge`, run the jury over confirmed candidates:

1. Call `librarian_cli lessons list --confirmed --json`. Each row carries `id`,
   `visibility`, and the full `candidate`. If the array is empty, tell the user
   there is nothing awaiting judgment and stop.
2. **Report the batch before spending anything.** Say how many candidates are
   confirmed and how many are `public`, and ask whether to proceed. This is the
   most expensive step in the pipeline. If the user declines, stop — nothing is
   written and every candidate stays `confirmed`.
3. For each candidate, in order:
   - **If `visibility` is `private`, dispatch no judges at all.** Call
     `librarian_cli lessons judge <id> '[]'` and move on. Private lessons run no
     jury; that is what makes cost scale with intent rather than artifact volume.
   - Otherwise spawn **both** `tribunal-judge-standard` and
     `tribunal-judge-adversarial` with the Task tool. Give each the candidate's
     `claim`, `rationale`, `evidence.resolution`, and `applies_to`, plus the
     rubric criteria for its visibility: for `org`, grounding / scope_accuracy /
     generality; for `public`, those three plus **disclosure** — does the text
     leak a credential, internal hostname, customer name, or proprietary detail?
   - Each judge returns a JSON object with `score`, `passed`, `judge_type`,
     `feedback_summary`, and `criterion_scores` — a map from **each rubric
     criterion name you gave it** to a score in `[0,1]`. **Tell each judge it
     must score every criterion you listed.** Every criterion in both lesson
     rubrics carries a floor, and a floor no judge scored makes the whole panel
     UNJUDGED — the candidate stays `confirmed` and is re-judged, at full cost,
     on the next run. So an omission here does not soften a verdict; it prevents
     one. That differs from tribunal, which degrades to a plain mean instead of
     refusing, and the shared judge agents describe tribunal's behavior.
     A judge that genuinely cannot assess a criterion should say so in
     `feedback_summary` and score its honest worst case rather than omit the
     key. Collect both verdicts into a JSON array **verbatim** — never summarize
     or reconstruct a judge's verdict.
   - Call `librarian_cli lessons judge <id> '<verdicts-json>'`. Record before
     moving to the next candidate, so an interrupted run costs at most one
     re-judgment. Recording a verdict also promotes the lesson in the same
     call — approved candidates land in the pool and rejected ones in the
     declined ledger, with no separate step. If the output instead says the
     lesson was judged but not promoted, the verdict is already recorded;
     retry once with `librarian_cli lessons promote <id>`, not by re-judging —
     re-judging would spend tokens again for a verdict that already exists.
     **If that retry itself fails, do not loop on it.** Add the id to the
     judged-but-not-promoted bucket and move to the next candidate; report it
     at the end alongside the retry command rather than retrying again here.
4. **If either judge fails to return parseable JSON, do not invent a verdict and
   do not drop that judge.** The array must still have one entry per empaneled
   judge: put that judge's raw output, as a JSON string, in its slot instead of
   a parsed verdict object. Pass that array to the CLI; it will exit 2, leave
   the candidate `confirmed`, and report that it could not be judged. Collect
   those ids and list them at the end so the user knows to re-run. A broken judge
   must never become a rejection — the artifact's watermark has already moved,
   so a false rejection buries a good lesson permanently.
5. **Finish on `librarian_cli lessons status`, not on your own tally.** It
   prints one line — pending, confirmed, approved, rejected, and **awaiting
   promotion** — read from disk, so it is the same kind of authoritative close
   the review walk ends on. Report those numbers as it gives them; a long batch
   is exactly where a running count kept in your head drifts.

   Two things the call cannot tell you, which you must still report yourself:

   - **could-not-judge** — those candidates stay `confirmed`, which on disk is
     indistinguishable from a candidate that was never judged this run. Keep
     the ids from step 4 and list them.
   - **which** lessons are awaiting promotion. The call gives the count; you
     have the ids. List them with `librarian_cli lessons promote <id>` as the
     next step, and don't fold them into "approved" — a lesson here has no pool
     entry yet. If your ids and the count disagree, trust the count and say so.

`scope_accuracy` is the criterion that matters most on a `version_independent`
candidate. The schema guarantees such a lesson **carries** a justification; this
criterion asks whether it is **true**.

## Safety rules

- **Never accept a proposal on the user's behalf without explicit confirmation.** Accepting writes a file to the user's typed memory store and that memory will be loaded into every future session in this project. Treat each accept like editing a CLAUDE.md.
- **Do not edit MEMORY.md directly.** `accept` updates the index for you; hand-editing risks duplicate entries or stale links.
- **Do not delete proposal files manually.** Reject (with a tombstone) is the cleanup path. Direct deletion would let the same body re-propose on the next scan.
- **Conflict-state proposals deserve a careful read.** When `conflict_state` is `near_duplicate` or `contradicts_existing`, surface the conflict to the user before they decide. Often the right answer is reject (the existing memory is better) or accept-and-then-prune (you can mention that follow-up).
- **Never confirm a lesson on the user's behalf without an explicit visibility.** Confirming commits a candidate toward leaving this machine — a decision separate from, and heavier than, accepting a memory proposal.
- **Never dispatch judges without reporting the batch and getting the user's go-ahead first.** Judge dispatch is the most expensive step in the pipeline; report the confirmed and `public` counts and wait before spawning a single judge.

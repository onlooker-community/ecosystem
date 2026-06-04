---
name: librarian
description: Review the librarian's pending memory promotion proposals queued from past sessions. Walk pending entries with the user one at a time, surfacing provenance and conflict state, and route each to accept (writes the typed memory file and updates MEMORY.md), reject (writes a body-hash tombstone so the same content won't re-propose), or defer (leave in the queue). Use when the user types `/librarian`, `/librarian review`, `/librarian triage`, `/librarian status`, or `/librarian list`, or asks to review librarian proposals.
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

If the user passes a free-form intent ("clear out the queue", "what's pending?"), map it to `review` or `list` as appropriate.

## Run the control surface

Source the plugin helpers and invoke `librarian_cli`. Run this in a single bash call when you need state:

```bash
set -uo pipefail
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-config.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-project-key.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-storage.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-emit.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/librarian-cli.sh"

# action is one of: list | show <id> | accept <id> | reject <id> [reason] | defer <id> | status
librarian_cli "<action>" "<args...>"
```

`librarian_cli` resolves the project key from the current working directory automatically and routes writes to the typed memory store under `${HOME}/.claude/projects/${CLAUDE_PROJECT_ENCODED}/memory/` (deriving the encoded path from `cwd` when the env var is unset).

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

## Safety rules

- **Never accept a proposal on the user's behalf without explicit confirmation.** Accepting writes a file to the user's typed memory store and that memory will be loaded into every future session in this project. Treat each accept like editing a CLAUDE.md.
- **Do not edit MEMORY.md directly.** `accept` updates the index for you; hand-editing risks duplicate entries or stale links.
- **Do not delete proposal files manually.** Reject (with a tombstone) is the cleanup path. Direct deletion would let the same body re-propose on the next scan.
- **Conflict-state proposals deserve a careful read.** When `conflict_state` is `near_duplicate` or `contradicts_existing`, surface the conflict to the user before they decide. Often the right answer is reject (the existing memory is better) or accept-and-then-prune (you can mention that follow-up).

---
name: historian
description: Embed historian chunks that were stored without a vector. When the local embedder (ollama) is down at SessionEnd, historian still stores each session's chunks but cannot embed them, and retrieval is embedding-only, so those chunks never surface. This walks the store and embeds them in place. Use when the user types `/historian backfill` or `/historian backfill --dry-run`, or asks to re-embed, backfill, or recover historian chunks after an embedder outage.
---

# Historian: Backfill

Retrieval only sees chunks that carry an `embedding`. When the embedder is down
at SessionEnd, historian stores the chunks anyway and leaves the vector off, and
nothing comes back for them later. `/historian backfill` is that later pass.

## Parse the request

- `backfill --dry-run`, or the user asks how much is missing → **count only**
- `backfill` → **count, report, then embed**
- `backfill --project <key>` → limit either of the above to one project key

## Run it

The script lives at `${CLAUDE_PLUGIN_ROOT}/scripts/backfill.sh` and reads config
from the current directory, the same way the SessionEnd hook reads it from the
session's cwd. Run it from the project directory.

1. **Always dry-run first**, so the user sees the size before anything runs:

   ```bash
   CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/backfill.sh" --dry-run
   ```

   Report the line it prints. If the user only asked for a count, stop here.

2. **Then the real run.** It only adds vectors to chunks that have none, keeps
   every other line byte for byte, and swaps each session file in only once it
   is complete, so this does not need a go-ahead the way a destructive step
   would. It does need time: each chunk is one local embed plus a few `jq`
   calls, roughly 0.1–0.2s, so thousands of chunks take minutes to tens of
   minutes. Past a few hundred, run it in the background rather than against
   the tool timeout:

   ```bash
   CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID}" bash "${CLAUDE_PLUGIN_ROOT}/scripts/backfill.sh"
   ```

3. **Report the final summary line verbatim** — embedded, failed (with the most
   common reason), and sessions skipped because an indexing run held their lock.
   Do not compute your own totals from the per-session lines.

## When it refuses or stops

It exits 1 and changes nothing in each of these cases. Relay the message and the
fix, and don't try to work around it.

- **The embedder is unreachable.** For ollama, `open -ga Ollama` starts it; then
  run the backfill again.
- **It stopped after five failures in a row.** The embedder went away mid-run.
  Everything embedded before that is saved; a second run picks up the rest.
- **The store holds vectors from a different model**, by label or by vector
  length. Vectors from two models are not comparable, and mixing them would
  break similarity for every stored chunk without any error. This is a model
  change, not something a backfill should paper over: tell the user which model
  the store holds and which one is configured, and let them decide.

`oversized` failures are chunks longer than `historian.embedder.max_input_chars`.
They fail the same way on every run and do not count toward the stop; mention
the count if the summary reports them.

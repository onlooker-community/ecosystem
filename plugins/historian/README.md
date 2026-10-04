# Historian

Episodic memory layer for past Claude Code sessions.

At every `SessionEnd`, Historian **launches a detached indexer** (`scripts/run-index.sh`) and returns immediately. That indexer reads the session transcript, splits it into overlapping chunks at turn boundaries — splitting mid-turn when a single turn is larger than the character target — redacts secret-shaped substrings, embeds each chunk via a local Ollama daemon, and persists the chunks under `~/.onlooker/historian/<project-key>/sessions/<session-id>.jsonl`. At every `UserPromptSubmit`, Historian embeds the prompt and retrieves the most similar past chunk (within a similarity floor and freshness window), then injects an `additionalContext` block whose first line is a "looks similar" pointer and whose body is a multi-line excerpt of the matched chunk.

Historian is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present. It is parallel to [`librarian`](../librarian) (which consolidates session decisions into the typed memory store) — both turn session-scoped material into something queryable across sessions, but at different levels of distillation. Librarian distills; historian preserves verbatim.

See [`docs/design.md`](docs/design.md) and [ADR-001](docs/adr/001-local-embeddings-only.md) for the full design, including the local-embeddings-by-default decision.

## How it works

| Hook | What Historian does |
|------|---------------------|
| `SessionEnd` | Launches `scripts/run-index.sh` detached and exits. The indexer reads the transcript at `transcript_path`, drops tool calls and tool results (keeps user + assistant messages), chunks inside the configured character target with overlap, runs the sanitizer (secret redaction + `[historian:skip]` markers + path-deny list), embeds each surviving chunk via the configured backend, and appends one JSONL line per chunk to the session's file. Emits `historian.indexing.*`, `historian.chunk.*`, `historian.embedder.unavailable` and `historian.embedder.failed` events along the way. |
| `UserPromptSubmit` | Rate-gated retrieval: short prompts, cooldown windows, and per-session caps short-circuit before the embedder runs. Otherwise embeds the prompt, streams every JSONL chunk for the project, and injects an `additionalContext` block — a header pointer line plus a multi-line excerpt — for the top cosine-similarity match above the floor. Excludes chunks from the current session id (a session retrieving its own chunks is the degenerate case). Emits `historian.retrieval.started` when the rate gate clears (with `prompt_chars`, plus `embed_chars` when the query had to be fitted to the embedder's `max_input_chars`), `historian.retrieval.surfaced` on the surfaced outcome, and `historian.retrieval.complete` with `outcome: surfaced\|empty\|skipped` and a `skip_reason` enum for skipped runs. |

## Activation

Install via the marketplace:

```
/plugin install historian@onlooker-community
```

See [`config.json`](config.json) for the full set of tunable defaults.

## Why indexing is detached

A `SessionEnd` hook that declares no timeout is killed at 1500ms, and the
indexing pass does not fit in that budget:

| work | measured |
|---|---|
| one warm embed | 51ms, so about 29 chunks fit the budget |
| a real 8.5MB transcript | 117 chunks, roughly 6s of embedding |
| a cold `nomic-embed-text` load | 11.24s, against an 8s request timeout |

Run inline, both failures were silent. Every `historian.indexing.complete`
with `outcome: "ok"` in the live log had indexed exactly **2 chunks** — not
historian working, just the only size that fit — while larger sessions appear
in `hook-health.jsonl` as `terminated` at 1503-1527ms. Detached, the pass can
take its cold load and its 117 embeds while the session closes immediately
(ONL-123).

Two consequences worth knowing:

- **The hook decides almost nothing.** It checks for a session id and
  launches. Every reason historian declines to index — no transcript path, no
  file at the path, a transcript below the minimum — is decided and reported
  by the indexer, so that reporting costs the `SessionEnd` path nothing.
- **The indexer holds its own lock**, keyed by session. The launcher must not
  take it: a process that acquires and then exits leaves a holder pid that is
  already dead, which the next caller reclaims as stale, leaving a lock that
  excludes nothing.

## Storage layout

```text
~/.onlooker/historian/<project-key>/
├── manifest.json                          # project metadata
├── retrieval-state/<session-id>.json      # rate-gate state: count + last_ms
└── sessions/<session-id>.jsonl            # one chunk per line, append-only
```

Each chunk line:

```json
{
  "chunk_id": "01J...",
  "session_id": "...",
  "chunk_index": 0,
  "start_turn_index": 0,
  "end_turn_index": 3,
  "body_redacted": "...",
  "body_chars": 2103,
  "created_at": "2026-06-04T...",
  "source": "local",
  "redaction_count": 0,
  "embedding": [0.123, 0.456, ...]
}
```

The `embedding` field is present only when that chunk's embed call actually
succeeded — which is not the same as the embedder having been *available*.
The availability probe asks `/api/tags`, which answers instantly from disk
whether or not the model is resident, so a cold daemon passes the probe and
then fails every embed. Chunks stored without a vector are still readable but
invisible to similarity retrieval until they are re-indexed.

How many there are is reported rather than left to be discovered: every
`historian.indexing.complete` carries `chunks_embedded` and
`chunks_unembedded`, and a run that lost chunks also emits
`historian.embedder.failed` with the reason (`timeout`, `http_error`,
`oversized`, …). That event means calls were attempted and lost;
`historian.embedder.unavailable` means the probe failed and none were tried.

### The query has the same limit, and no chunker

`max_input_chars` bounds what the embedder will accept. The chunker fits every
indexed turn to it, so on the indexing path hitting the limit means something is
misconfigured — and `oversized` is the right answer there. Nothing sits upstream
of the **retrieval query**, so a long prompt used to reach the embedder whole,
fail `oversized`, and leave retrieval with no vector to search on: 93 of 246
retrievals, 38%, over the five days after the counters shipped.

The prompt path now fits the query to the same limit before embedding, keeping
the head so a given opening text embeds to the same vector whatever follows it.
Truncating silently would just move the problem, so `historian.retrieval.started`
carries `embed_chars` — what was actually sent — alongside the `prompt_chars` it
always had. The field is **present only when the two differ**, so
`embed_chars < prompt_chars` is the truncation, readable from the one event
without knowing what the limit happened to be at the time.

## Embedder

Default backend is local **Ollama** with the `nomic-embed-text` model. Set up:

```bash
ollama pull nomic-embed-text
ollama serve   # run as a background service; the historian client expects 127.0.0.1:11434
```

Override the host or model in `.claude/settings.json` under
`historian.embedder.ollama.{host,model,request_timeout_seconds,keep_alive}`.
Set `historian.embedder.backend: "none"` to disable embedding entirely —
chunks index without vectors and retrieval no-ops.

Two knobs worth understanding:

- **`keep_alive`** (default `30m`) is how long Ollama holds the model in
  memory after a request. Ollama's own default is 5 minutes, which meant any
  session starting more than five minutes after the last embed paid a cold
  load — measured at 11.24s against the 8s request timeout, so it always
  failed, and failed silently.
- **`max_input_chars`** (default `6000`) is the largest body worth sending.
  `nomic-embed-text` holds roughly 2048 tokens and answers HTTP 500 above
  about 7k characters, saying nothing about size. The chunker splits turns to
  fit, so this is a backstop for a raised `chunk_target_chars` or a model with
  a smaller window; over it, historian reports `oversized` instead of spending
  a request to be told 500.

## Status

This plugin ships **scaffolding + the SessionEnd indexing pipeline + the UserPromptSubmit retrieval pipeline + Ollama embedder integration**. Deferred to follow-up landings:

- **fastembed sidecar and remote embedder backends** — opt-in via the two-key egress affirmation from [ADR-001](docs/adr/001-local-embeddings-only.md).
- **Prune (retention sweep) and purge (manual)** skills.
- **`/historian recall`, `/historian setup`, `/historian stats`, `/historian purge`** slash commands.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `jq` for JSON manipulation.
- `python3` for chunking and sanitization (no extra packages — stdlib only).

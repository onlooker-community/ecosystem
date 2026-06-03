# Historian — Plugin Design

**Plugin name:** `historian`
**Tagline:** *Recalls past sessions when they matter.*
**Status:** Design (pre-implementation)

Historian is the episodic memory layer. At `SessionEnd`, it chunks and embeds the session transcript and stores the vectors locally. At `UserPromptSubmit`, it computes the prompt's embedding, retrieves the most similar past chunks (above a similarity threshold), and surfaces them as `additionalContext` — "you worked on something like this in session X." The goal is precedent recall, not distillation: where librarian preserves the *conclusion* of a past session as a typed memory, historian preserves the *verbatim shape* of the conversation so future sessions can see what was actually tried, said, and rejected.

It sits in the [memory architecture](../../../docs/memory-architecture.md) parallel to librarian and curator. It operates on its own substrate (a local vector store) and does not write to the typed memory store. See [ADR-001](adr/001-local-embeddings-only.md) for the embeddings-locality decision — the design assumes a local embedding model and a local vector store.

---

## Failure Modes Historian Addresses

**A — "We've solved this exact bug before."** A user hits a flaky test and asks the model to investigate. The model debugs from scratch. Three months ago, the same flake was investigated in this repo, the root cause was identified, and the fix landed. Historian surfaces the past session's relevant chunks so the model can short-circuit to known-good context.

**B — "I tried X already and it didn't work."** A user begins exploring an approach; the model elaborates the approach in detail. Two weeks ago the same approach was tried and abandoned. Without historian, this is invisible — the typed memory store may have a `feedback` entry ("X doesn't work here") but the *why* is in the transcript. Historian retrieves the dead-end discussion, not just the conclusion.

**C — "What was the rationale we settled on?"** A code shape exists because of a past discussion. The commit message has "use the cached path" but no rationale. The typed memory store has "use cached path for hot writes" but no nuance. The original session has 40 turns of weighing tradeoffs. Historian retrieves the rationale-bearing chunks.

**D — "We were in a similar situation in the other repo."** Cross-repo recall — out of scope by default. Historian is per-project. Cross-project retrieval is an opt-in mode noted in [Open Questions](#open-questions).

---

## Architecture

```
SessionEnd hook fires
        │
        ▼
┌──────────────────────┐
│   Transcript Reader  │  reads full session transcript JSONL
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│   Chunker            │  rolling-window chunks; preserves turn boundaries
│                      │  default: 600-token chunks with 100-token overlap
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│   Sanitizer          │  redacts patterns: API keys, tokens, .env content
│                      │  drops chunks marked [historian:skip] by the user
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│   Local Embedder     │  ollama (default model: nomic-embed-text)
│                      │  fallback: fastembed via Python sidecar
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│   Vector Store       │  sqlite-vec at
│                      │  ~/.onlooker/historian/<project-key>/vectors.db
└──────────────────────┘

UserPromptSubmit hook fires
        │
        ▼
┌──────────────────────┐
│   Rate Gate          │  per-turn budget; cooldown after recent retrieval
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│   Query Embedder     │  embed the current user prompt
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│   ANN Lookup         │  top-K candidates by cosine; filter by min_similarity
│                      │  filter by age (configurable max_age_days)
└─────────┬────────────┘
          │ ≥1 result
          ▼
┌──────────────────────┐
│   Surfacer           │  emits additionalContext block with the top match
│                      │  ("Similar past session 47d ago — excerpt + link")
└──────────────────────┘
```

### Transcript Reader

At `SessionEnd`, reads the full transcript from `transcript_path` in the hook payload (same field compass and tribunal use). Parses as JSONL. Filters to user and assistant messages only — tool calls and tool results are dropped at this stage to keep the embedded content semantically focused. The resulting message list is the input to the chunker.

If the transcript is shorter than `min_transcript_chars_to_index` (default: 1200), historian skips indexing — the session is too short to plausibly produce a useful precedent.

### Chunker

Chunks the message list into overlapping windows:

- **Chunk size:** `chunk_target_tokens` (default: 600). Measured via the local tokenizer used by the embedding model.
- **Overlap:** `chunk_overlap_tokens` (default: 100). Ensures cross-chunk concepts aren't sliced apart.
- **Turn-boundary respect:** Chunks never split mid-turn. The chunker accumulates turns until adding the next would exceed the target; then it emits a chunk and starts a new one. If a single turn exceeds the target, it is emitted as-is and the next chunk begins after it (no mid-turn split).
- **Metadata per chunk:** `session_id`, `chunk_index`, `start_turn_id`, `end_turn_id`, `created_at`, `chunk_token_count`.

### Sanitizer

Before embedding, each chunk is scanned for:

1. **Secret patterns.** AWS-style keys (`AKIA...`), bearer tokens (`Bearer ey...`), Anthropic API keys, GitHub PATs (`ghp_...`), `.env`-style assignments (`SECRET_KEY=...`). Matches are replaced with `[REDACTED:secret]`.
2. **`[historian:skip]` markers.** A chunk containing the literal string `[historian:skip]` is dropped entirely. This is the in-band escape for users to mark sensitive turns.
3. **Path-aware redaction.** When a chunk references a path in `historian.never_index_paths`, the chunk is dropped. This is the path-level escape for "this directory's discussions should never be indexed."

Redacted chunks are still embedded (the surrounding content has value); dropped chunks are not. Both decisions are logged as `historian.chunk.sanitized` and `historian.chunk.dropped` events with reasons.

### Local Embedder

Embedding runs locally to keep transcript content off the wire and avoid per-prompt API cost. See [ADR-001](adr/001-local-embeddings-only.md) for the full reasoning.

Backends, in preference order:

1. **ollama with `nomic-embed-text`.** Ollama is the recommended runtime. The `nomic-embed-text` model (~110MB) produces 768-dim embeddings, works offline, and is cheap to install. Historian's setup skill walks users through `ollama pull nomic-embed-text` if needed.
2. **fastembed via Python sidecar.** A Python subprocess hosting fastembed (ONNX-based). Slower startup, no external runtime dependency. Used when ollama is not on PATH.
3. **Disabled.** If neither backend is available, historian emits `historian.embedder.unavailable` once per session and skips indexing. Retrieval also degrades to "no results."

Historian does not call a remote embedding API by default. Users who want a remote embedding model (e.g., for cross-repo retrieval or higher quality) can opt in via `embedder.backend: "remote"`, which gates on `data_egress.allow_remote_embedding: true` to make the egress decision explicit.

### Vector Store

`sqlite-vec` at `~/.onlooker/historian/<project-key>/vectors.db`. Schema:

```sql
CREATE TABLE chunks (
  chunk_id TEXT PRIMARY KEY,            -- ULID
  session_id TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  start_turn_id TEXT,
  end_turn_id TEXT,
  body_redacted TEXT NOT NULL,          -- post-sanitizer text
  created_at TEXT NOT NULL,
  source TEXT NOT NULL                  -- "local" today; future "team:<id>" etc.
);
CREATE VIRTUAL TABLE chunks_vec USING vec0(
  embedding FLOAT[768]
);
CREATE INDEX idx_chunks_session ON chunks(session_id);
CREATE INDEX idx_chunks_created ON chunks(created_at);
```

The chunk body (`body_redacted`) is stored alongside the embedding so retrieval can return the actual text without re-reading the transcript. Storage cost is bounded by retention: chunks older than `retention_days` (default: 365) are pruned on a daily-cap basis.

### Rate Gate

At `UserPromptSubmit`:

1. Skip if `disabled` in settings.
2. Skip if a retrieval has run in the last `cooldown_seconds` (default: 60) for this session. Avoids spamming retrieval on rapid-fire prompts.
3. Skip if more than `max_retrievals_per_session` (default: 5) have run this session. A precedent recall is most useful in the first handful of turns; later turns are usually deep in the current work and don't benefit.
4. Skip if the prompt is shorter than `min_prompt_chars` (default: 60). Short prompts ("ok", "next", "do it") have no semantic signal.

Each skip emits `historian.retrieval.skipped` with the reason.

### Query Embedder, ANN Lookup, and Surfacer

For retrievals that pass the rate gate:

1. Embed the prompt using the same backend as indexing.
2. `vec0` cosine-similarity lookup, top `retrieval_top_k` (default: 5).
3. Filter to candidates with `similarity >= min_similarity` (default: 0.55, calibrated against `nomic-embed-text` cosine distribution).
4. Filter to candidates within `max_age_days` (default: 180). Older chunks are deprioritized rather than dropped — they appear with a "long ago" hint in the surfaced context.
5. Filter out chunks from the current session (a session retrieving itself is a degenerate case).

The surfacer emits `additionalContext` of the form:

> Historian: a prompt 47 days ago looked similar. Excerpt (session 01J…):
>
> > [chunk text, truncated to 400 chars]
>
> Full session: `~/.onlooker/historian/<project-key>/sessions/<session_id>/transcript.json` (preserved on `historian.session.archive: true`; otherwise transcript reference only).

Only the top result is surfaced inline. The skill `/historian recall <query>` lets the user inspect more candidates.

---

## Integration Points

**Archivist.** Independent. Archivist preserves session-level distillations; historian preserves raw chunks. Same source (transcript) but different storage and different retrieval semantics.

**Librarian.** Independent at runtime. A future enhancement: when librarian classifies an artifact as "session-only — don't promote," historian could weight its source chunks lower in retrieval (the user has already signaled they're not durable). Deferred.

**Curator.** Independent. Curator audits the typed memory store; historian's substrate is the vector DB.

**Ecosystem substrate.** Historian writes to its own sub-path under `~/.onlooker/` and emits events via `onlooker-event.mjs`. No new substrate dependencies.

**Compass / Tribunal / Echo / Warden / Governor.** No interaction.

---

## Configuration (`config.json`)

```json
{
  "plugin_name": "historian",
  "storage_path": "${ONLOOKER_DIR:-$HOME/.onlooker}",
  "historian": {
    "enabled": false,
    "indexing": {
      "trigger": "SessionEnd",
      "min_transcript_chars_to_index": 1200,
      "chunk_target_tokens": 600,
      "chunk_overlap_tokens": 100,
      "retention_days": 365,
      "prune_daily_cap_chunks": 5000
    },
    "embedder": {
      "backend": "ollama",
      "ollama": {
        "model": "nomic-embed-text",
        "host": "http://127.0.0.1:11434",
        "request_timeout_seconds": 8
      },
      "fastembed": {
        "model": "BAAI/bge-small-en-v1.5",
        "sidecar_command": "python3 -m historian_fastembed"
      },
      "remote": {
        "enabled": false,
        "provider": "voyage",
        "model": "voyage-3-lite",
        "note": "Remote embedding sends transcript chunks to a third-party API. Requires data_egress.allow_remote_embedding: true to take effect."
      }
    },
    "sanitization": {
      "redact_secret_patterns": true,
      "drop_skip_marker": true,
      "never_index_paths": []
    },
    "retrieval": {
      "trigger": "UserPromptSubmit",
      "cooldown_seconds": 60,
      "max_retrievals_per_session": 5,
      "min_prompt_chars": 60,
      "retrieval_top_k": 5,
      "min_similarity": 0.55,
      "max_age_days": 180
    },
    "surfacer": {
      "surface_top_n": 1,
      "excerpt_chars_max": 400,
      "include_age_hint": true
    },
    "data_egress": {
      "allow_remote_embedding": false,
      "note": "When false, embedding stays local. When true, transcript chunks are sent to the configured remote provider for embedding only — chunks are not stored remotely."
    },
    "session_archive": {
      "enabled": false,
      "note": "When true, the full transcript at session end is copied to ~/.onlooker/historian/<key>/sessions/<session_id>/transcript.json so retrieval surfaces can link to the source. When false, only chunk bodies are retained."
    }
  }
}
```

---

## Events

| Event | Trigger | Key payload fields |
|---|---|---|
| `historian.indexing.started` | SessionEnd indexing run begins | `session_id`, `transcript_chars` |
| `historian.indexing.completed` | Run succeeds | `chunks_indexed`, `chunks_dropped`, `duration_ms` |
| `historian.indexing.skipped` | Indexing skipped | `reason: too_short\|embedder_unavailable\|disabled` |
| `historian.chunk.sanitized` | Secret patterns redacted in a chunk | `chunk_id`, `redaction_count` |
| `historian.chunk.dropped` | Chunk dropped entirely | `reason: skip_marker\|never_index_path` |
| `historian.embedder.unavailable` | Backend unreachable | `backend`, `error_summary` |
| `historian.retrieval.started` | UserPromptSubmit retrieval begins | `prompt_chars` |
| `historian.retrieval.skipped` | Skipped by rate gate | `reason: cooldown\|budget\|short_prompt\|disabled` |
| `historian.retrieval.empty` | No candidates above similarity floor | `top_similarity`, `min_similarity` |
| `historian.retrieval.surfaced` | A precedent was surfaced as additionalContext | `chunk_id`, `similarity`, `age_days` |
| `historian.prune.completed` | Daily retention prune ran | `chunks_pruned`, `chunks_remaining` |
| `historian.purge.completed` | User-triggered purge ran | `scope: session\|date_range\|all`, `chunks_purged` |

---

## Skills

**`/historian setup`** — checks for ollama on PATH, offers to install (or run the equivalent for fastembed), pulls the embedding model, and writes a confirmation to the storage dir.

**`/historian recall <query>`** — runs an ad-hoc retrieval against the current project's vector store. Returns the top K matches with similarity scores and full chunk bodies. Useful for "remind me what I tried last time" queries that don't naturally surface during a session.

**`/historian purge`** — interactive purge with three scopes: `session <id>` (remove all chunks from one session), `before <date>` (remove all chunks older than a date), `all` (full reset for this project). Always requires explicit user confirmation.

**`/historian stats`** — reports vector store size, chunk count, oldest chunk date, embedding model, last index run, last retrieval, retrieval-hit rate over last 30 days.

---

## Open Questions

1. **Cross-project retrieval.** A precedent in repo A may be relevant in repo B (e.g., the user solved a similar Postgres deadlock in two different services). Historian is per-project today. A `team:<id>` source mode could allow shared vector stores, but it introduces multi-user privacy concerns and a new substrate dependency. Deferred.

2. **Retrieval-hit calibration.** `min_similarity = 0.55` is a guess based on `nomic-embed-text`'s typical cosine distribution. A `/historian calibrate` skill could label a small set of past prompt-chunk pairs as relevant/irrelevant and tune the threshold per-project.

3. **Index-time vs. retrieval-time redaction.** Redaction at index time is permanent and safe. Retrieval-time redaction would let users tune redaction rules without re-indexing. The asymmetry: a secret indexed today can't be redacted later without a re-embed pass. The design picks index-time redaction as the default (irreversibility is the safer error) and leaves a re-embed path for the rare case of needing to update rules.

4. **Chunk overlap policy on long single turns.** A 4000-token assistant turn becomes a single chunk (no mid-turn split). The next chunk begins after it, losing the trailing-context overlap. Acceptable today; a "soft split" mode that breaks at paragraph boundaries within long turns is a future option.

5. **Session-archive storage cost.** With `session_archive: true`, the full transcript is preserved per session — typically tens of MB per active project per month. The retention cap applies to chunks, not archived transcripts; a separate `session_archive_retention_days` setting may be needed.

6. **Embedding-model versioning.** Re-running indexing with a different embedding model produces vectors in a different geometric space. The vector store has no concept of model version today. Adding `embedding_model` and `embedding_dim` columns and filtering retrieval by model match is straightforward but not yet decided.

7. **Coordination with `~/.onlooker/logs/onlooker-events.jsonl`.** The JSONL log itself contains a rich, structured record of past sessions. Historian could index event payloads (decisions, dead-ends, findings) alongside or instead of raw transcripts. The case against: the transcript already contains the conversation those events summarize; indexing both is duplication.

8. **Interaction with compaction.** A long session that compacts mid-flow has a truncated transcript at `SessionEnd`. Historian only sees the post-compaction tail. If pre-compaction content was important, it lives only in archivist. Whether historian should also index archivist artifacts (as a complement to transcript chunks) is a deferred design question.

---

## Non-Goals

- Does not call remote embedding APIs by default — local embedding is the architectural baseline (see [ADR-001](adr/001-local-embeddings-only.md)).
- Does not write to the typed memory store — that is librarian's job.
- Does not distill or summarize past sessions — preservation of verbatim shape is the point.
- Does not perform cross-project retrieval by default.
- Does not block any tool call — surfacer is informational only.
- Does not retain transcripts beyond chunk bodies unless `session_archive: true` is explicitly enabled.

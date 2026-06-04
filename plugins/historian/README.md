# Historian

Episodic memory layer for past Claude Code sessions.

At every `SessionEnd`, Historian reads the session transcript, splits it into overlapping chunks at turn boundaries, redacts secret-shaped substrings, embeds each chunk via a local Ollama daemon, and persists the chunks under `~/.onlooker/historian/<project-key>/sessions/<session-id>.jsonl`. At every `UserPromptSubmit`, Historian embeds the prompt and retrieves the most similar past chunk (within a similarity floor and freshness window), then injects an `additionalContext` block whose first line is a "looks similar" pointer and whose body is a multi-line excerpt of the matched chunk.

Historian is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present. It is parallel to [`librarian`](../librarian) (which consolidates session decisions into the typed memory store) — both turn session-scoped material into something queryable across sessions, but at different levels of distillation. Librarian distills; historian preserves verbatim.

See [`docs/design.md`](docs/design.md) and [ADR-001](docs/adr/001-local-embeddings-only.md) for the full design, including the local-embeddings-by-default decision.

## How it works

| Hook | What Historian does |
|------|---------------------|
| `SessionEnd` | Reads the transcript at `transcript_path`, drops tool calls and tool results (keeps user + assistant messages), chunks at turn boundaries inside the configured character target with overlap, runs the sanitizer (secret redaction + `[historian:skip]` markers + path-deny list), embeds each surviving chunk via the configured backend, and appends one JSONL line per chunk to the session's file. Emits `historian.indexing.*`, `historian.chunk.*`, and `historian.embedder.unavailable` events along the way. |
| `UserPromptSubmit` | Rate-gated retrieval: short prompts, cooldown windows, and per-session caps short-circuit before the embedder runs. Otherwise embeds the prompt, streams every JSONL chunk for the project, and injects an `additionalContext` block — a header pointer line plus a multi-line excerpt — for the top cosine-similarity match above the floor. Excludes chunks from the current session id (a session retrieving its own chunks is the degenerate case). Emits `historian.retrieval.started` when the rate gate clears, `historian.retrieval.surfaced` on the surfaced outcome, and `historian.retrieval.complete` with `outcome: surfaced\|empty\|skipped` and a `skip_reason` enum for skipped runs. |

## Activation

Historian is **off by default**. Enable per-project in `.claude/settings.json`:

```json
{
  "historian": {
    "enabled": true
  }
}
```

See [`config.json`](config.json) for the full set of tunable defaults.

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

The `embedding` field is present iff the embedder was available at indexing time. Chunks indexed without an embedder are still readable but invisible to similarity retrieval until they are re-indexed.

## Embedder

Default backend is local **Ollama** with the `nomic-embed-text` model. Set up:

```bash
ollama pull nomic-embed-text
ollama serve   # run as a background service; the historian client expects 127.0.0.1:11434
```

Override the host or model in `.claude/settings.json` under `historian.embedder.ollama.{host,model,request_timeout_seconds}`. Set `historian.embedder.backend: "none"` to disable embedding entirely — chunks index without vectors and retrieval no-ops.

## Status

This plugin ships **scaffolding + the SessionEnd indexing pipeline + the UserPromptSubmit retrieval pipeline + Ollama embedder integration**. Deferred to follow-up landings:

- **fastembed sidecar and remote embedder backends** — opt-in via the two-key egress affirmation from [ADR-001](docs/adr/001-local-embeddings-only.md).
- **Prune (retention sweep) and purge (manual)** skills.
- **`/historian recall`, `/historian setup`, `/historian stats`, `/historian purge`** slash commands.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `jq` for JSON manipulation.
- `python3` for chunking and sanitization (no extra packages — stdlib only).

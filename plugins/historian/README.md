# Historian

Episodic memory layer for past Claude Code sessions.

At every `SessionEnd`, Historian reads the session transcript, splits it into overlapping chunks at turn boundaries, redacts secret-shaped substrings, and persists the chunks under `~/.onlooker/historian/<project-key>/sessions/<session-id>.jsonl`. Future sessions can retrieve relevant past chunks when the user starts a similar problem.

Historian is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present. It is parallel to [`librarian`](../librarian) (which consolidates session decisions into the typed memory store) — both turn session-scoped material into something queryable across sessions, but at different levels of distillation. Librarian distills; historian preserves verbatim.

See [`docs/design.md`](docs/design.md) and [ADR-001](docs/adr/001-local-embeddings-only.md) for the full design, including the local-embeddings-by-default decision.

## How it works

| Hook | What Historian does |
|------|---------------------|
| `SessionEnd` | Reads the transcript at `transcript_path`, drops tool calls and tool results (keeps user + assistant messages), chunks at turn boundaries inside the configured character target with overlap, runs the sanitizer (secret redaction + `[historian:skip]` markers + path-deny list), and appends one JSONL line per chunk to the session's file. Emits `historian.indexing.*` and `historian.chunk.*` events along the way. |
| `UserPromptSubmit` | No-op in this PR — the rate gate, query embedder, ANN lookup, and surfacer are deferred to a follow-up that ships the retrieval pipeline alongside the first embedder backend. |

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
  "redaction_count": 0
}
```

## Status

This plugin ships **scaffolding + the SessionEnd indexing pipeline (transcript reader → chunker → sanitizer → JSONL store)**. Deferred to follow-up landings:

- **Retrieval and surfacer** — `UserPromptSubmit` rate gate, query embedding, ANN lookup, and `additionalContext` injection of the top match.
- **Embedder backends** — ollama (`nomic-embed-text`), fastembed sidecar, and remote (opt-in via the two-key egress affirmation from [ADR-001](docs/adr/001-local-embeddings-only.md)). Chunks are indexed without vectors today; the JSONL records make adding embeddings a future column-add, not a re-index.
- **Prune (retention sweep) and purge (manual)** skills.
- **`/historian recall`, `/historian setup`, `/historian stats`, `/historian purge`** slash commands.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `jq` for JSON manipulation.
- `python3` for chunking and sanitization (no extra packages — stdlib only).

# Archivist

Structured session memory across context truncation.

When Claude Code compacts a long conversation, Archivist extracts the decisions made, dead ends hit, and open questions raised — then reinjects the most relevant items at the start of the next session. Context windows are finite; important context shouldn't be.

Archivist is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

| Hook | What Archivist does |
|------|---------------------|
| `PreCompact` | Reads the transcript tail, calls `claude -p` with a structured-extraction prompt, validates referenced file paths against the current repo, and writes ULID-keyed JSON artifacts under `~/.onlooker/archivist/<project-key>/`. |
| `SessionStart` | Loads artifacts for the current project key, ranks them (pinned first, then recency), and emits them as invisible `additionalContext` within a token budget. |

## Activation

Archivist is **off by default**. Enable per-project in `.claude/settings.json`:

```json
{
  "archivist": {
    "enabled": true
  }
}
```

Or globally in `~/.claude/settings.json`.

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "archivist": {
    "enabled": false,
    "extraction": {
      "model": "claude-haiku-4-5-20251001",
      "max_output_tokens": 1500,
      "transcript_tail_chars": 60000
    },
    "injection": {
      "max_items": 8,
      "max_chars": 2400,
      "include_open_questions": true,
      "include_dead_ends": true
    }
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Must be `true` for any extraction or injection to run. |
| `extraction.model` | `claude-haiku-4-5-20251001` | Model used for transcript extraction. Haiku is fast and cheap; the extraction prompt is structured and does not require deep reasoning. |
| `extraction.max_output_tokens` | `1500` | Token ceiling for the extraction response. |
| `extraction.transcript_tail_chars` | `60000` | How many characters of the transcript tail to feed into extraction. Larger values capture more context at higher cost. |
| `injection.max_items` | `8` | Maximum number of artifacts to inject at `SessionStart`. |
| `injection.max_chars` | `2400` | Hard ceiling on total injected context characters. |
| `injection.include_open_questions` | `true` | Whether to inject open question artifacts. |
| `injection.include_dead_ends` | `true` | Whether to inject dead end artifacts. |

## Storage layout

```text
~/.onlooker/archivist/<project-key>/
├── manifest.json                    # project_key, remote_url, repo_root, last_compact_at
├── decisions/<ulid>.json
├── dead_ends/<ulid>.json
├── open_questions/<ulid>.json
└── pinned.json                      # ULIDs that always inject first, regardless of recency
```

Each artifact:

```json
{
  "id": "01J...",
  "kind": "decision",
  "project_key": "abc123def456",
  "source": "local",
  "created_at": "2026-05-22T10:00:00Z",
  "updated_at": "2026-05-22T10:00:00Z",
  "summary": "One-line headline.",
  "detail": "Optional longer text.",
  "files": ["relative/path/from/repo/root.ts"],
  "session_id": "..."
}
```

The `source` field is `"local"` today. Future cloud sync may set it to `"cloud"` or `"team:<id>"`.

## Cross-repo isolation

Two layers ensure artifacts from one repo never surface in another:

1. **Project keying** — the storage path is derived from the repo's git remote URL (SHA256, first 12 chars). Two different repos produce different keys.
2. **Path validation** — every `files[]` entry extracted from the transcript is resolved against `git rev-parse --show-toplevel`. Entries referencing paths outside the repo or that don't exist are stripped before persisting.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `claude` CLI on `PATH` for extraction.
- `jq` for JSON manipulation.

# Archivist

Structured session memory across context truncation. Extracts decisions, dead ends, and open questions on `PreCompact`, then reinjects the most important items at `SessionStart` for the same project.

Archivist is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

| Event | What archivist does |
|---|---|
| `PreCompact` | Reads the transcript tail, shells out to `claude -p` with a structured-extraction prompt, validates referenced paths against the current repo, and writes ULID-keyed JSON artifacts under `~/.onlooker/archivist/<project-key>/{decisions,dead_ends,open_questions}/`. |
| `SessionStart` | Loads artifacts for the current project key, ranks them (pinned first, then recency), and emits them as invisible `additionalContext` within a token budget. |

Project key is derived from `git remote get-url origin` (SHA256, first 12 chars). Repos without a remote fall back to a hash of the realpath of `git rev-parse --show-toplevel`. Worktrees of the same repo share a key.

## Storage layout

```
~/.onlooker/archivist/<project-key>/
├── manifest.json              # project_key, remote_url, repo_root, last_compact_at
├── decisions/<ulid>.json
├── dead_ends/<ulid>.json
├── open_questions/<ulid>.json
└── pinned.json                # ULIDs that always reinject first
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

The `source` field is `"local"` today. Future cloud-sync may set it to `"cloud"` or `"team:<id>"`.

## Configuration

Archivist is **opt-in**. Enable per-project by setting in your project's `.claude/settings.json`:

```json
{
  "archivist": {
    "enabled": true
  }
}
```

Or globally in `~/.claude/settings.json`. The default `plugins/archivist/config.json` exposes the full set of knobs (extraction model, token budgets, injection limits).

## Cross-repo isolation

Two layers of protection:

1. **Project keying** isolates artifacts on disk; reading the wrong project's archive is impossible because the key is derived from the current repo's remote.
2. **Path validation** during extraction: every `files[]` entry is resolved against `git rev-parse --show-toplevel` for the current repo. Entries that reference paths outside the repo (or that don't exist) are stripped before persisting.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `claude` CLI on `PATH` for extraction.
- `jq` for JSON manipulation (shipped with the Onlooker installer).

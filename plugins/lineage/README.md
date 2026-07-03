# Lineage

Per-change provenance for the Onlooker ecosystem — "why does this line exist?"

Git records *what* changed and scribe records a session's *intent*, but nothing
connects a **specific piece of code** to the prompt, agent, and session that
produced it. Lineage records provenance for every `Edit`/`Write`/`MultiEdit` at
`PostToolUse`, then answers `/lineage <file>:<line>` by joining its change records
to the transcripts [historian](../historian) preserves.

Lineage is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker
observability substrate (`~/.onlooker/`) is present.

## How it works

| Hook | Matcher | What Lineage does |
|------|---------|-------------------|
| `PostToolUse` | `Edit`, `Write`, `MultiEdit` | Derives the project key from `cwd`, reads the current turn from the session tracker, extracts the change's added content, redacts secrets + caps size, and appends one record to the per-project change ledger. Emits a lean `lineage.change.recorded` (metadata + digest, never the content). Skips disabled sessions, ignored paths, and files outside the repo. |

The `/lineage` skill is the query side: it reads the ledger and resolves each
change's originating prompt at query time. It makes no LLM call.

### Content-anchored provenance

Lineage records the **added content** of each change (redacted, capped at
`max_snippet_chars`). To answer "why does line N exist?", it reads the current
line's text and finds the most recent change whose added content contains it.
This is honest about what it is: *what change introduced this content, and why* —
not a git-blame-exact line mapping. If later edits move or rewrite the line, the
match is the most recent change that introduced the matching text.

### The historian join

Lineage records only `session_id` + `turn` (+ a `transcript_path` pointer) on the
hot path — never the prompt. The prompt is resolved lazily at query time:

1. **historian** — read the session's durable chunks at
   `~/.onlooker/historian/<project-key>/sessions/<session-id>.jsonl` and take the
   chunk whose turn range contains the change's turn (tolerant: nearest preceding,
   else the last chunk). This is the preferred source because historian persists
   transcripts long after the live `transcript_path` is gone.
2. **transcript** — fall back to the live `transcript_path` (the turn-th user
   message).
3. **none** — neither available; report the change without a prompt.

The content match — not the turn — is the precise provenance key; the prompt is
best-effort context, since historian's turn indices need not line up exactly with
the substrate's turn counter.

## Activation

Install the plugin in Claude from the marketplace with:

```
/plugin install lineage@onlooker-community
```

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "lineage": {
    "max_snippet_chars": 4000,
    "redact_secrets": true,
    "ignore_globs": ["**/.git/**", "**/node_modules/**", "**/dist/**", "**/*.lock"],
    "prompt_source": "historian_then_transcript"
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `max_snippet_chars` | `4000` | Cap on the added-content snippet stored per change. |
| `redact_secrets` | `true` | Scrub secret-shaped substrings (AWS/GitHub/Anthropic/OpenAI keys, bearer tokens, KEY=value secrets) before storing a snippet. |
| `ignore_globs` | `[".git", "node_modules", "dist", "*.lock"]` | Paths matching these are not recorded. Supports `**/<dir>/**` (path segment) and `**/*.<ext>` (suffix) shapes. |
| `prompt_source` | `"historian_then_transcript"` | Prompt-resolution strategy: `historian_then_transcript`, `historian_only`, or `transcript_only`. |

Config resolves in three layers, latest wins: plugin `config.json` →
`~/.claude/settings.json` → `<repo>/.claude/settings.json`.

## The `/lineage` query

| Invocation | Answers |
|------------|---------|
| `/lineage <file>` | Full change history for the file, newest first, each with its resolved prompt context. |
| `/lineage <file>:<line>` or `/lineage <file> --line N` | Which change introduced the content currently on line N — with the prompt/agent/session behind it. |
| `/lineage <file> --grep <text>` | Which change introduced content matching `<text>`. |
| `/lineage --status` | Ledger stats for the project (changes recorded, files touched). |

## Storage layout

```text
~/.onlooker/lineage/<project-key>/
├── changes.jsonl        # append-only, one change record per line
└── changes.jsonl.lock   # write lock
```

Each record: `{ change_id, ts, ts_epoch, session_id, turn?, tool, operation,
file_path, lines_added, lines_removed, bytes, edit_count, content_sha256,
added_snippets[], transcript_path }`. The added content lives only in this ledger;
the bus event carries metadata and the `content_sha256` digest, never the content.

Lineage honors `$ONLOOKER_DIR`; it never hardcodes `~/.onlooker`, so the test
suite's isolated temp home is respected.

## Events emitted

Lineage emits the canonical `lineage.*` surface from
[`@onlooker-community/schema`](https://github.com/onlooker-community/schema) v2.8.0+.

| Event | When |
|-------|------|
| `lineage.change.recorded` | At `PostToolUse`, after a change is appended to the ledger. Carries `project_key`, `session_id`, `file_path`, `tool`, `operation`, `change_id`, and metadata (`lines_added`/`lines_removed`/`bytes`/`edit_count`/`content_sha256`); no content. |
| `lineage.query.answered` | When `/lineage` answers. Carries `project_key`, `file_path`, `matches`, and (for line queries) `line` and `resolved_via`. |

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- The [`historian`](../historian) plugin enabled, for the most reliable prompt resolution. Without it, lineage falls back to the live transcript, then to "prompt unavailable."
- `jq` for JSON manipulation.
- `node` for canonical-event emission.
- `python3` for secret redaction (the same dependency historian uses for sanitizing).

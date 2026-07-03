# Scribe

Intent documentation from agent activity.

Scribe captures *why* changes were made — the problem context, the decisions and their reasons, the tradeoffs accepted, and the constraints that shaped the work — and distills them into a readable Markdown artifact at session end. Git logs and code comments record *what* changed; Scribe records the intent behind it.

Scribe is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

| Hook | What Scribe does |
|------|------------------|
| `SessionStart` | Creates storage directories and initializes a per-session state file with `captured_prompt` and `captured_at` set to null. |
| `UserPromptSubmit` | On the first turn of a session (when `captured_prompt` is still null), stores the prompt text — truncated to `capture.prompt_max_chars` — as the problem-statement seed. Subsequent turns are ignored, since the full transcript is available at Stop time. |
| `Stop` | Reads the full session transcript, runs a single Haiku extraction pass via `claude -p` to identify the problem, decisions, tradeoffs, constraints, and out-of-scope items, formats the result as a Markdown intent document, and writes it under `~/.onlooker/scribe/<project-key>/`. Emits `scribe.distill.complete`. |

The Stop hook silently skips when the session has fewer than `capture.min_turns` user turns or when no readable `transcript_path` is present in the hook input. Every hook always exits 0 — Scribe never blocks a session.

## Activation

Install the plugin in Claude from the marketplace with:

```
/plugin install scribe@onlooker-community
```

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "scribe": {
    "evaluator": {
      "model": "claude-haiku-4-5-20251001",
      "timeout": 60,
      "max_tokens": 2048,
      "temperature": 0.3
    },
    "capture": {
      "min_turns": 3,
      "prompt_max_chars": 1000,
      "transcript_chars_max": 40000
    },
    "output": {
      "mirror_to_project": false,
      "project_dir": "docs/decisions"
    }
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `evaluator.model` | `claude-haiku-4-5-20251001` | Model used for the intent-extraction pass. Haiku is fast and cheap; the extraction prompt is structured and does not require deep reasoning. |
| `evaluator.timeout` | `60` | Wall-clock timeout in seconds passed to the `timeout` command around the `claude -p` call. |
| `evaluator.max_tokens` | `2048` | Token ceiling for the extraction response. |
| `evaluator.temperature` | `0.3` | Sampling temperature for the extraction pass. |
| `capture.min_turns` | `3` | Minimum number of user turns in the transcript before a session is distilled. Shorter sessions are skipped silently. |
| `capture.prompt_max_chars` | `1000` | Maximum number of characters of the first prompt stored as the problem-statement seed. |
| `capture.transcript_chars_max` | `40000` | Maximum number of characters of the rendered transcript fed into extraction. Larger values capture more context at higher cost. |
| `output.mirror_to_project` | `false` | When `true`, also copies the generated document into the repo tree under `output.project_dir`. |
| `output.project_dir` | `docs/decisions` | Directory (relative to the repo root) the intent document is mirrored into when `output.mirror_to_project` is `true`. |

## Storage layout

```text
~/.onlooker/scribe/
├── sessions/
│   └── <session-id>.json              # per-session state: captured_prompt, captured_at
└── <project-key>/
    └── <date>-<session-short>.md       # intent document, e.g. 2026-06-04-01j8x9ab.md
```

When the project key cannot be resolved, the document is written under `~/.onlooker/scribe/unknown/` instead. With `output.mirror_to_project` enabled, the same Markdown file is also copied to `<repo-root>/<project_dir>/<date>-<session-short>.md`.

Project key: first 12 hex chars of SHA256 of `git remote get-url origin` (prefixed `remote:`), falling back to a SHA256 of the repo root realpath (prefixed `root:`). The scheme mirrors `tribunal` and is worktree-aware — a worktree shares its parent repo's key.

The intent document is a Markdown file with the following sections:

```markdown
# Session Intent: <date>

> <executive summary>

## Problem
## Decisions
## Tradeoffs
## Constraints
## Out of Scope
## Initial Prompt    # only when a prompt was captured
```

Each decision is rendered as a headline, its reason, and any considered-but-rejected alternatives. A footer records the short session ID, the generation timestamp, and the project root.

## Events emitted

Scribe emits the canonical `scribe.*` event surface from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema). All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

| Event | When |
|-------|------|
| `scribe.distill.complete` | After an intent document is written at session end. Includes `session_id`, `captures_processed`, and `artifacts_produced` (`2` when mirrored to the project tree, otherwise `1`). |

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission). Scribe declares `"requires": ["ecosystem"]`.
- `claude` CLI on `PATH` (the Stop hook shells out to `claude -p` for the extraction pass).
- `jq` for JSON manipulation.
- `node` for canonical-event emission.
- `shasum` or `sha256sum` for project-key derivation (standard on macOS and most Linux distributions).

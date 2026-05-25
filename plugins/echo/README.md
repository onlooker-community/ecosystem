# Echo

Prompt-change regression detection for the Onlooker ecosystem.

When a watched agent file is modified, Echo runs a single-judge quality pass on the file via `claude -p` and compares the score against a stored baseline. It reports whether the change **improved**, **degraded**, or had **no measurable effect** on prompt quality — giving every prompt edit a before/after signal instead of relying on intuition.

Echo is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

Echo registers a **Stop hook** that fires at the end of every Claude Code session. When triggered:

1. Detects which watched files changed (unstaged, staged, or untracked).
2. Filters against configured `watch_paths` and `exclude_paths` patterns.
3. For each matching file, builds a rubric prompt and calls `claude -p --max-turns 1` to score it on four criteria: role clarity, output format, criterion coverage, and internal consistency.
4. Compares the score to a stored baseline (if one exists) and emits `echo.improvement.detected` or `echo.regression.detected`.
5. Emits `echo.suite.complete` with aggregate drift, a `merge_recommended` flag, and duration.

The hook always exits 0 — it never blocks a session from ending.

## Activation

Echo is **off by default**. Enable it per-project in `.claude/settings.json`:

```json
{
  "echo": {
    "enabled": true
  }
}
```

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "echo": {
    "enabled": true,
    "watch_paths": ["plugins/*/agents/*.md"],
    "exclude_paths": [],
    "drift_threshold": 0.05,
    "evaluation": {
      "model": "claude-haiku-4-5-20251001",
      "timeout_seconds": 60
    }
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Must be `true` for any evaluation to run. |
| `watch_paths` | `["plugins/*/agents/*.md"]` | Glob patterns (relative to repo root) of files to watch. Bash extended glob syntax. |
| `exclude_paths` | `[]` | Patterns to exclude. `plugins/echo/**` is always excluded regardless of this setting. |
| `drift_threshold` | `0.05` | Minimum absolute score delta to classify a change as improvement or regression. Deltas below this are reported as neutral. |
| `evaluation.model` | `claude-haiku-4-5-20251001` | Model used for the quality pass. Haiku is fast and cheap; upgrade to Sonnet for higher-stakes repos. |
| `evaluation.timeout_seconds` | `60` | Per-file wall-clock timeout passed to the `timeout` command. |

## Scoring rubric

Each watched file is scored 0.0–1.0 on four equally-weighted criteria:

| Criterion | What it checks |
|-----------|---------------|
| **Role clarity** | Does the file clearly define what the agent is and what it must do? |
| **Output format** | Are output format and schema requirements unambiguous? |
| **Criterion coverage** | Are all evaluation dimensions specified with enough detail to apply consistently? |
| **Internal consistency** | No contradictory instructions; no undefined terms. |

A score ≥ 0.7 is considered "passed". A delta beyond `drift_threshold` in either direction is classified as improvement or regression.

## Storage layout

```text
~/.onlooker/echo/<project-key>/
├── baselines/
│   └── <test-id>.json          # one per watched file (test-id = first 16 hex of SHA256 of path)
└── run-<session-id>.json       # advisory summary written at end of each suite
```

Project key: first 12 hex chars of SHA256 of `git remote get-url origin`, falling back to a hash of the repo root realpath. This makes the key stable across directory moves and clones of the same repo.

## Events emitted

Echo emits the canonical `echo.*` event surface from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema) v2.2.0+. All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

| Event | When |
|-------|------|
| `echo.suite.started` | Before the evaluation loop begins. Includes `test_count` and `changed_file`. |
| `echo.improvement.detected` | A file's score increased beyond `drift_threshold`. |
| `echo.regression.detected` | A file's score decreased beyond `drift_threshold`. |
| `echo.suite.complete` | After all files are evaluated. Includes aggregate drift fields when a prior baseline exists. |

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- `claude` CLI on `PATH` (the hook shells out to `claude -p` for evaluation passes).
- `jq` for JSON manipulation.
- `node` for canonical-event emission.
- `python3` for millisecond timestamps (standard on macOS and most Linux distributions).

## Architecture decisions

Key decisions made during initial design are recorded in [`docs/adr/`](docs/adr/):

- [ADR-001](docs/adr/001-echo-as-separate-plugin.md) — Echo as a separate plugin, not an extension of Tribunal
- [ADR-002](docs/adr/002-direct-evaluation-vs-tribunal-pipeline.md) — Direct `claude -p` evaluation vs. routing through Tribunal's full pipeline
- [ADR-003](docs/adr/003-stop-hook-trigger.md) — Stop hook as the trigger mechanism

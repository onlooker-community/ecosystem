# Curator

Maintenance layer for the user's typed auto-memory store.

At every `SessionStart`, Curator runs cheap heuristic checks against the memories at `~/.claude/projects/<encoded-project>/memory/` — broken path references, stale ISO-8601 dates past the grace period, broken `MEMORY.md` index entries — and surfaces findings as a one-line pointer to `/curator review`. An LLM-backed contradiction sweep runs at most once per week per project. Curator never edits the memory store directly.

Curator is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present. It is parallel to [`cartographer`](../cartographer) (which audits hand-maintained instruction files like `CLAUDE.md`) — same audit shape, different substrate.

## How it works

| Hook | What Curator does |
|------|---------------------|
| `SessionStart` | Runs cheap-tier checks (date decay, path references, broken index, orphaned memories) inside a wall-clock budget. Writes findings under `~/.onlooker/curator/<project-key>/findings/`. Optionally runs the LLM contradiction sweep when the weekly interval has elapsed. Injects a one-line `additionalContext` pointer when open findings exist. |

## Activation

Curator is **off by default**. Enable per-project in `.claude/settings.json`:

```json
{
  "curator": {
    "enabled": true
  }
}
```

Or globally in `~/.claude/settings.json`. See [`config.json`](config.json) for the full set of tunable defaults.

## Storage layout

```text
~/.onlooker/curator/<project-key>/
├── manifest.json                    # project metadata
├── last_llm_sweep.json              # watermark for the weekly LLM pass
├── last_cheap_scan.json             # watermark for the per-session check
└── findings/<ulid>.json             # one finding per file
```

## Status

This plugin ships **scaffolding + cheap-tier checks (date decay, path references) + SessionStart surfacer**. The LLM contradiction sweep and the `/curator review` interactive walkthrough are deferred to follow-up commits. The usage tracker (memory recall frequency) becomes usable once the substrate `memory.recalled` event is wired up — see [`docs/design.md`](docs/design.md) Open Question #1.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `jq` for JSON manipulation.
- `git` to resolve the project key and (for the reference check) the repo root.
- `claude` CLI on `PATH` for the weekly LLM contradiction sweep (when enabled).

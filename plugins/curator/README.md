# Curator

Maintenance layer for the user's typed auto-memory store.

At every `SessionStart`, Curator runs cheap heuristic checks against the memories at `~/.claude/projects/<encoded-project>/memory/` — stale ISO-8601 dates past the grace period, broken path references, broken `MEMORY.md` index entries, and orphaned memory files — and surfaces findings as a one-line pointer to `/curator review`. Curator never edits the memory store directly.

The weekly LLM-backed contradiction sweep described in [`docs/design.md`](docs/design.md) is a future capability — see the **Status** section below for what's actually shipped today.

Curator is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present. It is parallel to [`cartographer`](../cartographer) (which audits hand-maintained instruction files like `CLAUDE.md`) — same audit shape, different substrate.

## How it works

| Hook | What Curator does |
|------|---------------------|
| `SessionStart` | Runs the four cheap-tier checks (date_decayed, path_broken, broken_index, orphaned_memory) against the memory store, inside a wall-clock budget (`cheap_checks.wall_clock_budget_ms`, default 500ms). Writes new findings under `~/.onlooker/curator/<project-key>/findings/` keyed by ULID, deduping repeat findings via `deduped_hash`. Injects a one-line `additionalContext` pointer when open findings exist. |

## Activation

Install Curator with `/plugin install curator@onlooker-community` — installing the plugin enables it. See [`config.json`](config.json) for the full set of tunable defaults.

## Storage layout

```text
~/.onlooker/curator/<project-key>/
├── manifest.json                    # project metadata
├── last_llm_sweep.json              # watermark for the weekly LLM pass
├── last_cheap_scan.json             # watermark for the per-session check
└── findings/<ulid>.json             # one finding per file
```

## Status

This plugin ships **scaffolding + four cheap-tier checks (date_decayed, path_broken, broken_index, orphaned_memory) + SessionStart surfacer**. Deferred to follow-up landings:

- **LLM contradiction sweep** — design and the watermark plumbing (`last_llm_sweep.json`) are in place; the Haiku pair-evaluation loop is not implemented. `llm_sweep.enabled` defaults to `false` and is a no-op until the sweep ships.
- **`/curator review` interactive walkthrough** — accept / prune / edit / reclassify / acknowledge / defer for surfaced findings.
- **Usage tracker** (zero-recall-window findings) — depends on a substrate-level `memory.recalled` emitter that doesn't exist yet. `usage_tracker.enabled` defaults to `false`; see [`docs/design.md`](docs/design.md) Open Question #1.
- **Symbol reference check** — backtick-wrapped identifiers grep'd against the repo. Not yet wired.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `jq` for JSON manipulation.
- `python3` for date math and path resolution.
- `git` to resolve the project key and (for the reference check) the repo root.

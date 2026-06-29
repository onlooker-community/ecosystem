# Librarian

Consolidates archivist's per-session artifacts into the user's durable typed memory store.

When a session ends, Librarian reads the decisions, dead-ends, and open questions that archivist captured during the session, decides which deserve to live beyond the session, classifies them into the four memory types (user, feedback, project, reference), and queues them as proposals for explicit confirmation. By default Librarian never writes to the typed memory store directly — see [ADR-001](docs/adr/001-propose-dont-auto-write.md) for why.

Librarian is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present. It depends on [archivist](../archivist) at the data layer (it reads archivist's artifact files) but not at runtime.

## How it works

| Hook | What Librarian does |
|------|---------------------|
| `SessionEnd` | Scans archivist artifacts since last watermark, runs the durability filter, classifies surviving candidates with Haiku, detects conflicts/duplicates against existing memories, writes proposals to `~/.onlooker/librarian/<project-key>/proposals/`. |
| `SessionStart` | Counts pending proposals; if any, injects a single-line pointer pointing the user at `/librarian review`. |

## Activation

Install Librarian from the marketplace:

```
/plugin install librarian@onlooker-community
```

Installing the plugin enables it. See [`config.json`](config.json) for the full set of tunable defaults.

## Storage layout

```text
~/.onlooker/librarian/<project-key>/
├── manifest.json                    # project metadata
├── last_scan.json                   # watermark for incremental scans
├── proposals/<ulid>.json            # pending/resolved proposals
└── tombstones/<body_hash>.json      # records of rejected/pruned promotions
```

Accepted promotions land in the user's typed memory store at `~/.claude/projects/<encoded-project>/memory/` with a `source: "librarian"` provenance trailer in the frontmatter.

## Status

This plugin is **in design / scaffolding phase**. The hook entry points exist and load cleanly but the scan + classify + propose pipeline is not yet implemented. See [`docs/design.md`](docs/design.md) for the full design and [`docs/adr/001-propose-dont-auto-write.md`](docs/adr/001-propose-dont-auto-write.md) for the load-bearing decision.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `archivist` plugin installed (Librarian reads its artifact files; Librarian degrades to no-op if archivist is absent).
- `claude` CLI on `PATH` for the classifier call.
- `jq` for JSON manipulation.

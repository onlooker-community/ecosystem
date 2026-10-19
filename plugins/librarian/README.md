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

## Measurements

**[2026-10-17 transform baseline](docs/measurements/2026-10-17-transform-baseline/README.md) / ONL-110** — 36 archivist artifacts transformed and juried, `claude-haiku-4-5-20251001`. **0 of 10** candidates cleared the gate, and the standard judge passed none either — `disclosure` is 0/10 for *both* judges at a min-mean of 0.417 against a 0.9 floor, which gates every candidate before the judges' disagreement matters. That contradicts ONL-110's "passes the standard judge, then fails adversarial review," which rested on n=2. Only 11 of 36 artifacts produced a candidate at all, and the *richest* artifacts transformed worst (2/9 in the top detail quartile, against 6/9 mid-corpus).

**[2026-10-18 defined criteria](docs/measurements/2026-10-18-defined-criteria/README.md) / ONL-110** — the baseline's own candidates, re-judged after the judge prompt began defining each criterion instead of naming it. The judges had been reading `disclosure` as "acknowledges caveats" when it is a leak check. Gate **0/10 → 5/10**, disclosure **0/10 → 10/10**, and a synthetic leaky candidate still scores 0.0 on it. What still fails is `scope_accuracy` and `grounding`, with the adversarial judge dissenting.

```bash
plugins/librarian/scripts/measure-lesson-transform.sh --dry-run --samples 36   # show the plan, spend nothing
plugins/librarian/scripts/rejudge-lesson-baseline.sh <samples.json> <dir>      # re-score fixed candidates after a judge-side change
```

The harness measures in a throwaway `ONLOOKER_DIR`: a decline is terminal, so an in-place run would burn its own corpus and have nothing to measure the second time.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `archivist` plugin installed (Librarian reads its artifact files; Librarian degrades to no-op if archivist is absent).
- `claude` CLI on `PATH` for the classifier call.
- `jq` for JSON manipulation.

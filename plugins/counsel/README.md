# Counsel

Weekly synthesis and coaching brief from the full observability stack.

Counsel reads every plugin's events from your onlooker log, runs a single synthesis pass to surface recurring patterns, improvement opportunities, and wins, and writes a structured Markdown brief. At session start, when the last brief has gone stale, it regenerates one and injects it as invisible context — turning weeks of accumulated agent telemetry into a short, actionable read.

Counsel is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

| Hook | What Counsel does |
|------|-------------------|
| `SessionStart` | Resolves the project key, checks whether the latest brief is older than `synthesis_interval_days`. If stale (and enough events exist), reads the last `lookback_days` of events from the onlooker log, calls `claude -p` with a synthesis prompt, writes a `YYYY-WW.md` brief under `~/.onlooker/counsel/<project-key>/briefs/`, emits `counsel.brief.generated`, and injects the brief as `additionalContext`. |

The synthesis pass produces a structured JSON object — `summary`, `patterns`, `recommendations` (each with `title`, `rationale`, and a `high`/`medium`/`low` `priority`), `wins`, and `watch` — which Counsel formats into the Markdown brief.

Counsel partitions the event stream by source plugin, recognizing `tribunal`, `echo`, `sentinel`, `warden`, `oracle`, and `meridian` events (everything else maps to a generic `onlooker_events` source). The synthesis prompt focuses on recurring failure modes and blocked gates, prompt regression trends, budget and resource pressure, quality trends over time, and what the team is consistently doing well.

The hook always exits 0 — it never blocks a session from starting. It skips silently when Counsel is disabled, the directory has no project key (non-git), the latest brief is still fresh, or fewer than `capture.min_events` events fall inside the lookback window.

## On-demand brief — `/counsel`

The SessionStart path only regenerates when the latest brief is stale. To run the weekly review immediately — regardless of freshness — invoke the `/counsel` skill. It forces a synthesis pass, writes the brief, emits `counsel.brief.generated`, and renders the result in the conversation instead of injecting it invisibly.

| Invocation | What it does |
|------------|--------------|
| `/counsel` | Forces a fresh synthesis now (bypassing the staleness gate), writes `<YYYY-WW>.md`, and prints the brief. Re-running in the same ISO week overwrites that week's brief in place. |
| `/counsel --show` | Renders the most recent brief already on disk. No LLM call, no events emitted. |
| `/counsel --status` | Reports the latest brief's age, last-generated time, and whether it is stale. No LLM call. |

The on-demand path bypasses only the staleness gate — output, events, storage layout, project keying, and the `capture.min_events` floor are identical to the SessionStart path. If too few events fall inside the lookback window, `/counsel` reports that rather than emitting a thin brief.

## Activation

Counsel is **on by default**. Disable it per-project in `.claude/settings.json` (or globally in `~/.claude/settings.json`):

```json
{
  "counsel": {
    "enabled": false
  }
}
```

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "counsel": {
    "enabled": true,
    "synthesis_interval_days": 7,
    "lookback_days": 30,
    "evaluator": {
      "model": "claude-haiku-4-5-20251001",
      "timeout": 90,
      "max_tokens": 4096,
      "temperature": 0.4
    },
    "capture": {
      "min_events": 10,
      "events_chars_max": 60000
    },
    "output": {
      "brief_max_chars": 3000
    }
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | Set to `false` to skip all synthesis and injection. |
| `synthesis_interval_days` | `7` | Minimum age (in days) of the latest brief before a new one is generated. A brief younger than this is considered fresh and the hook skips. |
| `lookback_days` | `30` | How far back in the event log to read when synthesizing a brief. |
| `evaluator.model` | `claude-haiku-4-5-20251001` | Model used for the synthesis pass. Haiku is fast and cheap; upgrade for higher-stakes repos. |
| `evaluator.timeout` | `90` | Per-call wall-clock timeout (seconds) passed to the `timeout` command around `claude -p`. |
| `evaluator.max_tokens` | `4096` | Token ceiling for the synthesis response. |
| `evaluator.temperature` | `0.4` | Sampling temperature for the synthesis pass. |
| `capture.min_events` | `10` | Minimum number of events in the lookback window required to generate a brief. Below this, the hook skips silently. |
| `capture.events_chars_max` | `60000` | Hard ceiling on the characters of summarized event text fed into the synthesis prompt. |
| `output.brief_max_chars` | `3000` | Hard ceiling on the brief characters injected as session context. |

## Storage layout

```text
~/.onlooker/counsel/<project-key>/
└── briefs/
    └── <YYYY-WW>.md          # one brief per ISO week; newest sorts last
```

Briefs are named by ISO year and week (`date '+%G-%V'`). The injected brief is always the lexicographically newest `.md` file in the directory; its file modification time is what the staleness check compares against `synthesis_interval_days`. When no project key can be derived, briefs fall back to `~/.onlooker/counsel/unknown/briefs/`.

Project key: first 12 hex chars of SHA256 of `remote:<git-remote-origin-url>`, falling back to SHA256 of `root:<repo-root>` for repos without a remote. The repo root is resolved through the git common directory, so worktrees of the same repo share a key. This mirrors the tribunal and scribe keying scheme.

## Events emitted

Counsel emits its event surface through [`@onlooker-community/schema`](https://github.com/onlooker-community/schema). All events are validated against the schema before being appended to `~/.onlooker/logs/onlooker-events.jsonl`.

| Event | When |
|-------|------|
| `counsel.brief.generated` | After a brief is written. Payload includes `period_start`, `period_end`, `recommendation_count`, and `sources_consulted` (the set of source plugins present in the analyzed event batch). |

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- `claude` CLI on `PATH` (the hook shells out to `claude -p` for the synthesis pass).
- `jq` for JSON manipulation.
- `node` for canonical-event emission.

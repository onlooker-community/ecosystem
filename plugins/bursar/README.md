# Bursar

Multi-session, per-project budget accounting for the Onlooker ecosystem.

Bursar rolls each session's spend into a per-project ledger when the session ends, and surfaces "this project burned $X this week" at the next session start. Named for the officer who keeps an institution's accounts, it answers a question [`governor`](../governor) cannot: not "is *this* session over budget?" but "what has *this project* cost me lately?"

Where governor regulates a single session, bursar is the cross-session rollup. The two do not call each other — bursar reads governor's per-session totals off the shared event bus (`governor.session.complete`) and degrades gracefully when governor is not running.

Bursar is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

| Hook | Matcher | What Bursar does |
|------|---------|------------------|
| `SessionStart` | `*` | Derives the project key from the session `cwd`, writes a breadcrumb so `SessionEnd` can attribute spend, then sums the per-project ledger over the active window and surfaces the total as `additionalContext`. Emits `bursar.rollup.surfaced` (or `bursar.rollup.skipped` when there is nothing in the window). |
| `SessionEnd` | `*` | Resolves the ending session's project key (breadcrumb → substrate session tracker → live cwd), reads the session's spend from the latest `governor.session.complete` on the event bus, upserts one record into the per-project ledger, and emits `bursar.session.recorded`. |

### Attributing a session to a project

`SessionEnd`'s hook payload only reliably carries `session_id`, so bursar cannot derive a project key from a `cwd` at that point. Instead, `SessionStart` — which *does* receive `cwd` — derives the [project key](../tribunal/scripts/lib/tribunal-project-key.sh) (SHA256 of the git origin URL, or the repo root for remote-less repos) and stashes a breadcrumb at `$ONLOOKER_DIR/bursar/sessions/<session-id>.json`. `SessionEnd` reads it back, falling back to the substrate session tracker's recorded `cwd`, then to the live `cwd`.

Records are keyed by `session_id`: re-recording a session replaces its line rather than appending, so a `SessionEnd` that fires more than once is idempotent.

### Reading spend off the bus

On `SessionEnd`, bursar scans `~/.onlooker/logs/onlooker-events.jsonl` for the **last** `governor.session.complete` matching the session — governor re-emits cumulatively, so the final one carries the session's totals. It records `total_cost_usd`, `total_tokens`, and `total_api_calls`. When no such event exists (governor disabled or absent), the session is still recorded with `governor_present: false` and no cost, and the surfaced message degrades to a session count.

## Activation

Install the plugin in Claude from the marketplace with:

```
/plugin install bursar@onlooker-community
```

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "bursar": {
    "window": "rolling_7d",
    "week_start": "monday",
    "surface_at_session_start": true,
    "min_cost_to_surface_usd": 0
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `window` | `"rolling_7d"` | Rollup window. `"rolling_7d"` sums the trailing 7×24h; `"calendar_week"` sums from the most recent week start. |
| `week_start` | `"monday"` | First day of the calendar week — `"monday"` or `"sunday"`. Only consulted when `window` is `"calendar_week"`. |
| `surface_at_session_start` | `true` | When `false`, bursar still records sessions and writes breadcrumbs but prints nothing at `SessionStart`. |
| `min_cost_to_surface_usd` | `0` | Suppress the `SessionStart` message when the windowed total is below this dollar amount. |

Config resolves in three layers, latest wins: plugin `config.json` → `~/.claude/settings.json` → `<repo>/.claude/settings.json`.

## Storage layout

```text
~/.onlooker/bursar/
├── projects/
│   └── <project-key>/
│       ├── sessions.jsonl        # one record per session (project key sanitized to [a-zA-Z0-9-_])
│       └── sessions.jsonl.lock   # upsert lock
└── sessions/
    └── <session-id>.json         # SessionStart→SessionEnd breadcrumb (removed once recorded)
```

Each ledger line is a JSON record: `{ ts, ts_epoch, session_id, project_key, cost_usd?, tokens?, api_calls?, governor_present, model? }`. `ts_epoch` (seconds) is stored alongside the RFC3339 `ts` so windowing is a portable numeric compare with no date parsing. Cost fields are omitted when governor was not running for the session.

Bursar honors `$ONLOOKER_DIR`; it never hardcodes `~/.onlooker`, so the test suite's isolated temp home is respected.

## Events emitted

Bursar emits the canonical `bursar.*` event surface from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema) v2.7.0+. All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

| Event | When |
|-------|------|
| `bursar.session.recorded` | At `SessionEnd`, after a session's spend is upserted into the project ledger. Carries `project_key`, `session_id`, `governor_present`, and — when governor supplied them — `cost_usd`, `tokens`, `api_calls`, `model`. |
| `bursar.rollup.surfaced` | At `SessionStart`, when a windowed total is shown. Carries `project_key`, `window`, `window_start`, `total_cost_usd`, `session_count`, `total_tokens`, and `sessions_with_cost`. |
| `bursar.rollup.skipped` | At `SessionStart`, when nothing is surfaced because the window is empty. Carries `reason` and `project_key`. |

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- The [`governor`](../governor) plugin enabled, to populate the dollar figures bursar rolls up. Without it, bursar still reports session counts.
- `jq` for JSON manipulation.
- `node` for canonical-event emission.
- `awk` for fractional cost arithmetic and token formatting (standard on macOS and most Linux distributions).

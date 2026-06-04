# Governor

Resource governance and budget enforcement for the Onlooker ecosystem.

Governor tracks per-session token and cost spend, gates `Task` spawns before they exceed a configurable budget ceiling, and emits `governor.*` events for audit. Named for the steam-engine governor — the flyweight device that throttles a machine back before it runs away — it keeps a session's subagent fan-out inside a spend envelope instead of letting it accelerate unchecked.

Governor is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

Governor keeps a per-session JSONL ledger and consults it on every `Task` spawn. Accounting is two-phase: the gate writes a *reservation* before a spawn runs so concurrent spawns each see the others' in-flight cost, and completion *cancels* that reservation and records observed spend.

| Hook | Matcher | What Governor does |
|------|---------|--------------------|
| `SessionStart` | `*` | Creates `~/.onlooker/governance/ledgers/`, sweeps stale lock directories left by crashed prior sessions (emitting `governor.lock.stale_cleared` for each), and checks that the global policy file exists (warns to stderr if missing — never blocks). |
| `PreToolUse` | `Task` | The gate. Estimates tokens for the spawn, reads consumed tokens from the ledger under an atomic check-and-reserve lock, decides allow or block, writes a reservation when allowing, and emits `governor.gate.checked`. |
| `PostToolUse` | `Task` | Records the completed call: negates the reservation estimate, adds observed `actual_tokens` when the tool response carries usage counts, appends a record to the ledger, and emits `governor.call.recorded`. |
| `Stop` | `*` | Reads cumulative totals from the ledger and emits `governor.session.complete` with token, cost, and call summaries plus an `under_budget` flag. |

### The gate decision

On each `Task` spawn, Governor estimates the spawn's token cost, adds it to the session's consumed tokens, and compares the projection against two thresholds:

- **`ceiling_exceeded`** — projected tokens exceed `tokens_default × hard_stop_margin`. **Always blocks**, regardless of enforcement mode.
- **`budget_exceeded`** — projected tokens exceed `tokens_default` but stay under the hard ceiling. Blocks only in `hard` enforcement; in `soft` enforcement the spawn is allowed and only the event is emitted.
- **`lock_timeout`** — the gate lock could not be acquired within its timeout. Treated as a block in `hard` enforcement.

To block, the hook writes `{"decision":"block","reason":"..."}` to stdout (the Claude Code `PreToolUse` block protocol) and still exits 0. All other paths allow the spawn. Every decision — allow or block — emits `governor.gate.checked` with the decision, reason, estimate, and remaining budget.

### Token and cost estimation

Governor does not know the model a spawn will use, so estimates are a planning-time upper bound. Tokens are estimated from the tool-input JSON using a **tier table** of characters-per-token ratios:

| Content tier | Characters per token |
|--------------|----------------------|
| ASCII prose | 4.0 |
| Code / JSON | 3.0 |
| Mixed | 2.5 |
| Non-Latin | 1.5 |

The raw estimate is multiplied by `safety_margin` before the gate check. Cost is derived from tokens at a blended ~$9 per million (Sonnet-class $3/M input + $15/M output, assuming a 50/50 split). When a `PostToolUse` response carries `usage.input_tokens` / `usage.output_tokens`, the actual count is recorded alongside the estimate and the running total converges to real spend.

## Activation

Governor is **off by default**. Enable it per-project in `.claude/settings.json`:

```json
{
  "governor": {
    "enabled": true
  }
}
```

Or globally in `~/.claude/settings.json`. While disabled, every hook skips silently and no ledger is written.

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "governor": {
    "enabled": false,
    "enforcement": "soft",
    "global_policy_path": "~/.onlooker/governance/global-policy.yaml",
    "session": {
      "tokens_default": 100000,
      "cost_usd_default": 1.0,
      "reserve_pct": 10
    },
    "estimation": {
      "safety_margin": 1.3,
      "hard_stop_margin": 1.5,
      "method": "tier_table"
    }
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Must be `true` for any tracking, gating, or event emission to run. |
| `enforcement` | `"soft"` | `"soft"` tracks and emits events but never blocks on a budget overrun; `"hard"` blocks `Task` spawns once the budget is exceeded. A `ceiling_exceeded` overrun blocks in both modes. |
| `global_policy_path` | `"~/.onlooker/governance/global-policy.yaml"` | Path checked at `SessionStart`. Missing file warns to stderr only — the session runs without a global ceiling. |
| `session.tokens_default` | `100000` | Per-session token budget. Projecting past this triggers `budget_exceeded`. Overridable per session via the `ONLOOKER_SESSION_BUDGET_TOKENS` environment variable. |
| `session.cost_usd_default` | `1.0` | Per-session cost budget in USD. Used by the `Stop` hook to set `under_budget`. |
| `session.reserve_pct` | `10` | Percentage of the budget held in reserve. |
| `estimation.safety_margin` | `1.3` | Multiplier applied to the raw token estimate before the gate check. |
| `estimation.hard_stop_margin` | `1.5` | Multiplier on `tokens_default` that defines the hard ceiling (`ceiling_exceeded`), which blocks regardless of enforcement mode. |
| `estimation.method` | `"tier_table"` | Estimation strategy. Only `tier_table` is implemented. |

Config resolves in three layers, latest wins: plugin `config.json` → `~/.claude/settings.json` → `<repo>/.claude/settings.json`.

## Storage layout

```text
~/.onlooker/governance/
├── ledgers/
│   ├── <session-id>.jsonl          # one ledger per session (id sanitized to [a-zA-Z0-9-_])
│   ├── <session-id>.jsonl.lock     # gate / write lock
│   └── <session-id>.jsonl.poisoned # marker written if a ledger write fails after retries
└── global-policy.yaml              # advisory global ceiling (optional, checked at SessionStart)
```

Each ledger line is a JSON record. The gate appends `record_type: "reservation"` rows with a positive `estimated_tokens`; completion appends rows with a negated `estimated_tokens` (canceling the reservation) plus `actual_tokens` when usage is reported. Session totals sum `estimated_tokens + actual_tokens` across every row, so the running total resolves to in-flight estimates plus completed actuals.

Governor honors `$ONLOOKER_DIR`; it never hardcodes `~/.onlooker`, so the test suite's isolated temp home is respected.

## Events emitted

Governor emits the canonical `governor.*` event surface from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema) v2.4.0+. All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

| Event | When |
|-------|------|
| `governor.gate.checked` | On every `Task` spawn at the `PreToolUse` gate. Carries `decision`, `estimated_tokens`, `tokens_available`, `estimation_method`, `safety_margin`, and a `reason` when blocked. |
| `governor.call.recorded` | After a `Task` completes (`PostToolUse`). Carries `estimated_tokens`, `cost_usd_estimated`, `duration_ms`, and — when usage is reported — `actual_tokens` and `estimation_error_pct`. |
| `governor.session.complete` | At `Stop`. Carries `total_tokens`, `total_cost_usd`, `total_api_calls`, `budget_usd`, `under_budget`, and `ledger_poisoned`. |
| `governor.lock.stale_cleared` | At `SessionStart`, once per stale lock directory swept (older than 60 seconds). |
| `governor.ledger.write_failed` | When a ledger write fails after its retry budget; the ledger is poisoned and `unrecorded_tokens` is reported. |

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- `jq` for JSON manipulation.
- `node` for canonical-event emission.
- `awk` for fractional token and cost arithmetic (standard on macOS and most Linux distributions).

# Cartographer

Proactive, periodic auditor of the persistent instruction layer shaping every Claude Code session.

Cartographer discovers all `CLAUDE.md`, `AGENTS.md`, and `.claude/rules/` files in your project, builds a semantic map of their relationships, and surfaces contradictions, stale references, dead rules, and scope collisions — before they cause expensive agent misbehavior.

Every other Onlooker plugin is reactive. Cartographer is the exception.

## What it detects

| Finding type | Description |
|---|---|
| `contradiction` | Two rules that cannot both be satisfied simultaneously |
| `dead_rule` | A rule fully subsumed by a more specific rule elsewhere |
| `stale_ref` | A reference to a file path, tool, or command that no longer exists |
| `scope_collision` | A project rule that duplicates or silently overrides a global `~/.claude/CLAUDE.md` rule |

## Installation

Cartographer is part of the Onlooker ecosystem monorepo. It requires the ecosystem plugin to be installed first.

## Activation

Install Cartographer from the marketplace and it runs automatically:

```
/plugin install cartographer@onlooker-community
```

## Usage

### Automatic (SessionStart)

Once enabled, Cartographer audits automatically every 24 hours (configurable). The audit runs as a detached background process — your session is not blocked.

Findings appear in the next `/cartographer` invocation or in any event log consumer subscribed to `cartographer.issue.found`.

### On-demand

```
/cartographer              # full audit, foreground
/cartographer --verbose    # show all known findings (no bus events)
/cartographer --status     # running state + last completion time
/cartographer --force      # kill running audit and restart
/cartographer --phase=contradiction   # single-phase audit
/cartographer --scope=src/            # scoped to a subdirectory
```

## Configuration

All options are optional. Defaults shown:

```json
{
  "cartographer": {
    "audit_interval_hours": 24,
    "phase_timeout_seconds": 60,
    "total_timeout_seconds": 600,
    "extraction": {
      "model": "claude-haiku-4-5-20251001",
      "max_output_tokens": 2048
    },
    "synthesis": {
      "model": "claude-haiku-4-5-20251001",
      "max_output_tokens": 2048
    },
    "exclude_paths": [
      "node_modules", ".git", "vendor", ".venv",
      "dist", ".next", ".nuxt", "build", "__pycache__"
    ]
  }
}
```

**Note:** Overriding `exclude_paths` replaces the entire list. Repeat the defaults plus your additions if you want to extend rather than replace.

## Privacy

- All analysis uses `claude -p` via your existing Claude Code session — no separate API key, no new data recipient.
- Findings are stored only in `~/.onlooker/cartographer/<project-key>/` on your local machine.
- The event log (`~/.onlooker/logs/onlooker-events.jsonl`) contains finding excerpts (capped in the payload) but never full file contents.

## Storage

```
~/.onlooker/cartographer/<project-key>/
├── last_audit_at          # unix epoch of last completed audit
├── audit.lock             # flock target or PID file
├── audit.log              # background audit stdout/stderr
├── extracts/              # per-file content hash cache
├── findings/              # one JSON file per unique finding (atomic writes)
└── dedup/                 # empty sentinel per emitted finding hash
```

## Event delivery

`cartographer.issue.found` events are delivered at-least-once. If the audit process crashes between emitting an event and writing the dedup sentinel, the finding is re-emitted once on the next run. Downstream consumers must deduplicate on `payload.finding_hash`.

## Non-goals

Cartographer will not:
- Modify any instruction file
- Block Write or Edit tool calls
- Enforce rule priority or style
- Operate across machines (findings are local)
- Replace human review of instruction files

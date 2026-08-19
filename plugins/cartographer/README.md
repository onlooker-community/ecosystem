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
| `undocumented_entity` | Something that exists on disk — a plugin, a skill — that no instruction file mentions |

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
/cartographer --type=stale_ref        # one finding type; skips the other analyzers
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

### Detecting omissions

Every other check reads the instruction files and tests what it finds against
the filesystem. `undocumented_entity` runs the other way: it enumerates
entities on disk and flags any whose name appears in no instruction file. That
is the one kind of drift the other checks structurally cannot see — something
absent produces no reference to follow. The mention check is case-sensitive,
so `plugins/foo/` documented only as "Foo" is still flagged as undocumented.

This phase only runs as part of a full audit (SessionStart or manual
`/cartographer`) — it is skipped on the targeted post-write audit that runs
after you edit an instruction file, so editing `CLAUDE.md` never produces an
omission finding on its own.

```json
{
  "cartographer": {
    "undocumented_entity": {
      "enabled": true,
      "globs": ["plugins/*/", "skills/*/"],
      "exclude": [],
      "max_findings": 20
    }
  }
}
```

`globs` are relative to the repository root, and a glob matching nothing is
simply inert — the defaults do nothing in a repository without those
directories. The list is deliberately opt-in: most of a repository has no
business being named in `CLAUDE.md`, so only classes where you expect the
documentation to be *complete* belong here.

**Note:** as with `exclude_paths`, overriding `globs` or `exclude` replaces the
entire list rather than extending it. Repeat the defaults alongside your
additions if you mean to extend.

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

## Finding lifecycle

A finding is born `resolved: false` and refreshed on every audit that observes it again. A **full** audit that completes without a failed phase then retires anything it did not observe: absence is the evidence that the drift is gone, so those records get `resolved: true` and a `resolved_at` stamp, and `/cartographer` stops rendering them. `/cartographer --verbose` still lists them, tagged `[RESOLVED]`, so you can confirm a fix took.

Two runs deliberately retire nothing, because neither looked widely enough for absence to mean anything:

- **Targeted post-write audits** evaluate a single file, so nearly every stored finding is absent for reasons unrelated to being fixed.
- **Partial runs** (any phase timed out or errored) produce no findings for the phase that failed, which is indistinguishable from its findings being gone.

Resolution is not terminal. The dedup sentinel outlives it, so drift that is reintroduced returns as a *known* finding — that path reopens the record (`resolved: false`, `resolved_at` cleared) rather than filing a new one, keeping `first_seen_at` intact. Without that, a recurring finding would stay hidden forever.

## Event delivery

`cartographer.issue.found` events are delivered at-least-once. If the audit process crashes between emitting an event and writing the dedup sentinel, the finding is re-emitted once on the next run. Downstream consumers must deduplicate on `payload.finding_hash`.

`cartographer.issue.resolved` carries the same `finding_hash`, so a consumer can close the finding it opened and hold open/closed state from the log alone. It is emitted only by a run that looked everywhere: a targeted audit sees a single file and a run with a failed phase sees an incomplete corpus, so neither can treat a finding's absence as evidence its drift is gone.

The payload carries no timestamp of its own. The envelope's required `timestamp` is the resolution time, since the event is emitted from the sweep that flips the record.

`cartographer.audit.complete` reports `resolved_finding_count` for the same reason and under the same condition — a run that skipped the sweep omits the field entirely rather than reporting `0`, which would read as "swept, retired nothing".

## Non-goals

Cartographer will not:
- Modify any instruction file
- Block Write or Edit tool calls
- Enforce rule priority or style
- Operate across machines (findings are local)
- Replace human review of instruction files

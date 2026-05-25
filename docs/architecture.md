# Ecosystem Architecture

This document describes how the Onlooker ecosystem fits together: the shared substrate, the plugin layer, the event bus, and the configuration system.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Claude Code session                                            │
│                                                                 │
│  ┌─────────────┐  ┌───────────┐  ┌──────────┐  ┌──────────┐  │
│  │  ecosystem  │  │ archivist │  │ tribunal │  │   echo   │  │
│  │  (substrate)│  │  plugin   │  │  plugin  │  │  plugin  │  │
│  └──────┬──────┘  └─────┬─────┘  └────┬─────┘  └────┬─────┘  │
│         │               │             │              │         │
│         └───────────────┴─────────────┴──────────────┘         │
│                               │                                 │
│                    ┌──────────▼──────────┐                     │
│                    │  onlooker-event.mjs  │  schema-validated   │
│                    │  (canonical emitter) │  event envelope     │
│                    └──────────┬──────────┘                     │
│                               │                                 │
│                    ┌──────────▼──────────┐                     │
│                    │  ~/.onlooker/logs/  │                     │
│                    │  onlooker-events    │  append-only JSONL   │
│                    │  .jsonl             │                     │
│                    └─────────────────────┘                     │
└─────────────────────────────────────────────────────────────────┘
```

## The substrate layer: `ecosystem`

The `ecosystem` plugin (repo root) is not optional — it provides the infrastructure every other plugin builds on:

| Component | What it does |
|-----------|-------------|
| `~/.onlooker/` directory | Shared storage root, created by the Onlooker installer. All plugins store artifacts here under their own sub-path. |
| `scripts/lib/onlooker-event.mjs` | Canonical event emitter. Accepts a JSON payload on stdin, validates it against `@onlooker-community/schema`, and appends the signed event envelope to the JSONL log. |
| `scripts/lib/onlooker-schema.sh` | Bash wrapper for schema validation without Node. |
| `scripts/lib/validate-path.sh` | Sets canonical `$ONLOOKER_*` environment variables (log path, tracker dirs, etc.) so every hook uses consistent paths. |
| Session trackers | `SessionStart`, `Stop`, `PreCompact` hooks that emit `session.*`, `tool.*`, `turn.*` events for the observability layer. |
| Prompt rules | `UserPromptSubmit` hook that injects declarative guidance on regex match. |

## The plugin layer

Plugins are independent packages under `plugins/<name>/`. Each has its own:
- `config.json` — defaults for all knobs.
- `hooks.json` — declares which Claude Code hook events to subscribe to.
- `.claude-plugin/plugin.json` — marketplace manifest (name, version, description, agents, skills).
- `CHANGELOG.md` + release-please track — versioned independently of the ecosystem.

Plugins communicate by **emitting events**, not by calling each other directly. An Echo evaluation and a Tribunal jury run both write to the same JSONL log; a dashboard or downstream consumer can query across both.

### Plugin dependency model

All plugins depend on `ecosystem`. No plugin depends on another plugin at runtime. This means:
- Tribunal does not require Archivist to be installed.
- Echo does not require Tribunal to be installed (despite evaluating similar things — see [Echo ADR-002](../plugins/echo/docs/adr/002-direct-evaluation-vs-tribunal-pipeline.md)).
- You can install any subset of plugins and the others still work.

## The event bus

Every observable event flows through `onlooker-event.mjs` before being written to disk. The emitter:

1. Wraps the plugin-supplied payload in a canonical envelope:
   ```json
   {
     "id": "01J...",
     "plugin": "echo",
     "session_id": "...",
     "event_type": "echo.suite.complete",
     "timestamp": "2026-05-24T...",
     "schema_version": "2.2.0",
     "payload": { ... }
   }
   ```
2. Validates the envelope and payload against [`@onlooker-community/schema`](https://github.com/onlooker-community/schema). If validation fails, the event is rejected and the hook surfaces an error — no silent data corruption.
3. Appends the validated event as a single JSON line to `~/.onlooker/logs/onlooker-events.jsonl`.

The schema is versioned independently and published to npm. Plugin shell scripts source `onlooker-event.mjs` at runtime so schema validation always reflects the installed version.

## Project keying

Every plugin that stores per-project artifacts uses the same key derivation:

```
key = first 12 hex chars of SHA256(git remote get-url origin)
```

If no remote exists (local-only repo), the key falls back to `SHA256(realpath of git toplevel)`.

This means:
- Two clones of the same repo share the same key and therefore the same baselines, memories, and Tribunal history.
- Git worktrees of the same repo also share the key.
- Moving the repo directory does not change the key (remote URL is stable).

## Configuration system

Each plugin reads config in two steps:

1. **Plugin defaults** — `plugins/<name>/config.json`. Ships with the plugin; defines all available knobs and their defaults.
2. **Settings overlay** — `.claude/settings.json` (repo-level) or `~/.claude/settings.json` (global). The plugin-specific key (e.g., `echo`, `tribunal`) is deep-merged onto the defaults.

Repo-level settings take precedence over global; both override plugin defaults. This lets you:
- Enable a plugin for a specific project without touching your global config.
- Override the evaluation model for a high-stakes repo without affecting others.

## Architecture decisions

Ecosystem-level decisions are recorded in [`docs/adr/`](adr/):

- [ADR-001](adr/001-claude-code-hooks-as-integration-surface.md) — Claude Code hooks as the integration surface
- [ADR-002](adr/002-centralized-jsonl-event-log.md) — Centralized JSONL event log with schema validation
- [ADR-003](adr/003-ulid-over-uuid.md) — ULID for all identifiers
- [ADR-004](adr/004-plugin-config-with-settings-overlay.md) — Per-plugin config with settings.json overlay

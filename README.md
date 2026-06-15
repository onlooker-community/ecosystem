# Onlooker Ecosystem

[![Test](https://github.com/onlooker-community/ecosystem/actions/workflows/test.yml/badge.svg)](https://github.com/onlooker-community/ecosystem/actions/workflows/test.yml)
[![Coverage](https://github.com/onlooker-community/ecosystem/actions/workflows/coverage.yml/badge.svg)](https://github.com/onlooker-community/ecosystem/actions/workflows/coverage.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Plugins](https://img.shields.io/badge/plugins-17-8A2BE2)](#plugins)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)

Composable observability, memory, and quality-gate plugins for [Claude Code](https://docs.claude.com/en/docs/claude-code) — all built on the [Onlooker](https://onlooker.dev) event substrate.

The ecosystem is a **Claude Code plugin marketplace**. Every plugin writes to a shared, schema-validated event log, derives a stable project key from your git remote, and stores artifacts under `~/.onlooker/` — so plugins compose without stepping on each other, and every event is queryable in one place.

---

## Core concepts

- **Shared event substrate.** The `ecosystem` plugin is always-on infrastructure. Every other plugin emits [canonical Onlooker events](https://github.com/onlooker-community/schema) through `scripts/lib/onlooker-event.mjs`; nothing writes the log directly. Event types follow `<plugin>.<noun>.<verb>` (e.g. `tribunal.gate.blocked`, `inspector.run.completed`).
- **Plugins compose, they don't couple.** Plugins coordinate only by reading and writing the JSONL event bus — no plugin calls another directly. Every plugin depends on `ecosystem`; none depends on another plugin. So `bursar` can roll up `governor.session.complete` events without importing governor, and degrade gracefully when it's absent.
- **Stable project keys.** Artifacts are partitioned by a project key — the first 12 hex chars of `SHA256(remote:<origin-url>)`, falling back to the repo root for remote-less checkouts — so history stays attached to a project across clones and worktrees.
- **One storage root.** Runtime artifacts live under `$ONLOOKER_DIR` (default `$HOME/.onlooker/`), namespaced per plugin and project. Plugins fail soft when it's absent — a plugin never blocks a session it wasn't invited to.
- **Opt-in by default.** Most plugins ship disabled and are enabled per-project or globally via `settings.json`. The substrate, and a couple of low-cost reporters, are the exceptions (see the [table](#plugins)).

For how these fit together, see [docs/architecture.md](docs/architecture.md) and the [ecosystem-level ADRs](docs/adr/).

---

## Plugins

Seventeen plugins, grouped by what they do. Each links to its own README and config.

### Substrate

| Plugin | Description | Default |
|--------|-------------|---------|
| [`ecosystem`](./) | Observability substrate: `$ONLOOKER_DIR` storage, canonical schema-validated event emission, session/tool tracking hooks, and prompt rules. Required by every other plugin. | Always on |

### Memory & context

| Plugin | Description | Default |
|--------|-------------|---------|
| [`archivist`](./plugins/archivist) | Structured session memory across context truncation. Extracts decisions, dead ends, and open questions on `PreCompact`; reinjects the most relevant items at the next `SessionStart`. | Opt-in |
| [`librarian`](./plugins/librarian) | Consolidation layer between archivist's per-session artifacts and your durable typed memory store. Detects which decisions deserve to persist, classifies them, and queues proposals for explicit confirmation. | Opt-in |
| [`curator`](./plugins/curator) | Maintenance layer for the typed auto-memory store. Runs cheap heuristic checks (date-decayed, broken paths, orphaned entries) within a wall-clock budget and points you at `/curator review`. Never edits memory directly. | Opt-in |
| [`historian`](./plugins/historian) | Episodic memory. Chunks and sanitizes the transcript at `SessionEnd`, then embeds each prompt on `UserPromptSubmit` to retrieve relevant past context. | Opt-in |
| [`scribe`](./plugins/scribe) | Intent documentation from agent activity. Captures *why* changes were made — problem context, decisions, tradeoffs — and distills them into readable artifacts at session end. | Enabled |
| [`cartographer`](./plugins/cartographer) | Proactive auditor of the instruction layer (`CLAUDE.md`, `AGENTS.md`, `.claude/rules/`). Maps relationships and surfaces contradictions, shadowing, gaps, and drift before they cause misbehavior. | Opt-in |

### Quality & verification

| Plugin | Description | Default |
|--------|-------------|---------|
| [`tribunal`](./plugins/tribunal) | Multi-agent quality gates. Wraps a task in an Actor → Jury → Meta-Judge → Gate loop and retries the Actor with critique until the gate passes or `max_iterations` is reached. Grounded in LLM-as-a-Judge (Zheng et al. 2023) and LLM-as-a-Meta-Judge (Wu et al. 2024). | Skill always on; Stop hook opt-in |
| [`echo`](./plugins/echo) | Prompt-change regression detection. When a watched agent file is modified, runs a single-judge quality pass and compares against a stored baseline to report improved, degraded, or neutral. | Opt-in |
| [`assayer`](./plugins/assayer) | Claim verification. Parses the agent's final message for testable claims ("tests pass", "build is green") and checks each against the actual command results in the transcript. Catches lying-without-malice. Advisory when on. | Opt-in |
| [`inspector`](./plugins/inspector) | Per-edit lint and typecheck gate. Runs the project's configured checks on just the touched file after every `Write`/`Edit`/`MultiEdit`, so the agent sees its own type errors before claiming success. Cheaper than a full project verify; complements assayer. | Opt-in |

### Safety & alignment

| Plugin | Description | Default |
|--------|-------------|---------|
| [`compass`](./plugins/compass) | Pre-write intent clarity gate. Intercepts write-class tool calls and requires a confidence threshold before allowing them, evaluating the pending write against the prior assistant turn to avoid false positives on question-answer turns. | Opt-in |
| [`warden`](./plugins/warden) | Untrusted-content gate. Scans `WebFetch`/`Read` content for prompt-injection patterns and, on a hit, closes a session-scoped gate that blocks `Write`/`Edit`/`Bash` until you clear it. Applies Meta's Agents Rule of Two by removing external actions while untrusted content is in play. | Opt-in |

### Cost & governance

| Plugin | Description | Default |
|--------|-------------|---------|
| [`governor`](./plugins/governor) | Resource governance and budget enforcement. Tracks per-session token and cost spend and gates `Task` spawns before they exceed a configurable ceiling. Named for the steam-engine governor that regulates output. | Opt-in |
| [`bursar`](./plugins/bursar) | Multi-session, per-project budget accounting. Rolls each session's spend into a per-project ledger on `SessionEnd` and surfaces "this project burned $X this week" at `SessionStart`. The cross-session rollup to governor's single-session view. | Opt-in |

### Observability & insight

| Plugin | Description | Default |
|--------|-------------|---------|
| [`lineage`](./plugins/lineage) | Per-change provenance — answers "why does this line exist?". Records session/turn metadata plus a redacted, size-capped snippet for every edit, then traces a file or line back to the change (and prompt) that introduced it. | Opt-in |
| [`counsel`](./plugins/counsel) | Weekly synthesis across the full observability stack. Reads every plugin's event log, produces a structured improvement brief, and injects it at session start when the last brief is stale. | Enabled |

---

## Quick start

### Use it in Claude Code

Add the marketplace, then install the plugins you want:

```text
/plugin marketplace add onlooker-community/ecosystem
/plugin install ecosystem@onlooker-community
/plugin install inspector@onlooker-community
```

`ecosystem` is the substrate every other plugin builds on — install it first. Most plugins are disabled by default; enable and tune them under their namespace key in `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project). See [ADR-004](docs/adr/004-plugin-config-with-settings-overlay.md) for the configuration model.

### Onlooker CLI

The companion CLI reads the shared event log for cross-session reporting:

```bash
brew tap onlooker-community/tap
brew install onlooker

# Run the guided setup wizard
onlooker setup
```

---

## Configuration

Each plugin ships defaults in its own `config.json`. Override them per-namespace in `settings.json`:

```jsonc
{
  // ~/.claude/settings.json (global) or .claude/settings.json (per-project)
  "inspector": { "enabled": true },
  "tribunal": { "enabled": true, "stop_hook": { "enabled": true } }
}
```

Project-level settings override global by the plugin's namespace key.

---

## Development

Install tools with [mise](https://mise.jdx.dev/) (`mise install`), then install dependencies:

```bash
npm ci
npm test                # bats + schema validation tests
npm run test:shellcheck
npm run test:ci         # shellcheck + bats + schema + lint
```

Tests live under `test/bats/` and `test/node/` and use an isolated temp home, so nothing writes to your real `~/.onlooker/`.

Hooks emit [canonical Onlooker events](https://github.com/onlooker-community/schema) via `scripts/lib/onlooker-event.mjs`; shared bash helpers live in `scripts/lib/`. New event types must be registered in `@onlooker-community/schema` before a plugin emits them — the emitter validates the envelope.

### Adding a plugin

1. Create `plugins/<name>/` with `.claude-plugin/plugin.json`, `config.json`, and `hooks/hooks.json`.
2. Emit only through `scripts/lib/onlooker-event.mjs`, and register your event types in `@onlooker-community/schema` first.
3. Store artifacts under `${ONLOOKER_DIR:-$HOME/.onlooker}/<name>/<project-key>/` — never hardcode the path.
4. Register the plugin in `.claude-plugin/marketplace.json`, `release-please-config.json`, and `.release-please-manifest.json`.

Commits follow [Conventional Commits](https://www.conventionalcommits.org); releases are automated with [release-please](https://github.com/googleapis/release-please) per plugin.

---

## Prompt rules

The ecosystem plugin ships a `UserPromptSubmit` hook that injects declarative guidance when a user prompt matches a regex. Rules fire deterministically on literal prompt-text patterns, filling the niche skills can't: guidance that must fire regardless of whether the model would have chosen a skill.

Rules live in two files:

- `~/.onlooker/prompt-rules.json` — global, applies across all projects
- `<repo>/.claude/prompt-rules.json` — project-level, overrides global by `id`

```json
{
  "rules": [
    {
      "id": "rule-no-verify-warning",
      "pattern": "--no-verify",
      "guidance": "Skipping hooks usually masks the real issue. Investigate the failure first.",
      "fire_once_per_session": true,
      "enabled": true
    }
  ]
}
```

`pattern` is POSIX ERE (`[[ =~ ]]` semantics). Run `/list-prompt-rules` to see active rules and per-session fire state.

---

## License

[MIT](./LICENSE) © Onlooker Community

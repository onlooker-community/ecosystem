# Onlooker Ecosystem

[![Test](https://github.com/onlooker-community/ecosystem/actions/workflows/test.yml/badge.svg)](https://github.com/onlooker-community/ecosystem/actions/workflows/test.yml)
[![Coverage](https://github.com/onlooker-community/ecosystem/actions/workflows/coverage.yml/badge.svg)](https://github.com/onlooker-community/ecosystem/actions/workflows/coverage.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![Plugins](https://img.shields.io/badge/plugins-17-8A2BE2)](#plugins)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)

Composable observability, memory, and quality-gate plugins for [Claude Code](https://docs.claude.com/en/docs/claude-code) — all built on the [Onlooker](https://onlooker.dev) event substrate.

The ecosystem is a **Claude Code plugin marketplace**. Its plugins write to a shared, schema-validated event log, derives a stable project key from your git remote, and stores artifacts under `~/.onlooker/` — so plugins compose without stepping on each other, and every event is queryable in one place.

---

## Core concepts

- **Shared event substrate.** The `ecosystem` plugin is always-on infrastructure. The other plugins emit [canonical Onlooker events](https://github.com/onlooker-community/schema) through its `scripts/lib/onlooker-event.mjs`; nothing writes the log directly. Event types follow `<plugin>.<noun>.<verb>` (e.g. `tribunal.gate.blocked`, `inspector.run.completed`).
- **Plugins compose, they don't couple.** Plugins coordinate only by reading and writing the JSONL event bus — no plugin calls another directly, and none depends on another plugin. So `bursar` can roll up `governor.session.complete` events without importing governor, and degrade gracefully when it's absent. A plugin needs `ecosystem` only to emit: without it, it still runs and keeps its own files, but writes nothing to the event log, so the plugins that read the log, such as `bursar` and `counsel`, find nothing there.
- **Stable project keys.** Artifacts are partitioned by a project key — the first 12 hex chars of `SHA256(remote:<origin-url>)`, falling back to the repo root for remote-less checkouts — so history stays attached to a project across clones and worktrees.
- **One storage root.** Runtime artifacts live under `$ONLOOKER_DIR` (default `$HOME/.onlooker/`), namespaced per plugin and project. Plugins fail soft when it's absent — a plugin never blocks a session it wasn't invited to.
- **Installing a plugin enables it.** There is no per-plugin on/off switch. Some features inside a plugin are opt-in through `settings.json`, such as tribunal's Stop hook.

For how these fit together, see [docs/architecture.md](docs/architecture.md) and the [ecosystem-level ADRs](docs/adr/).

---

## Plugins

The `ecosystem` substrate and seventeen plugins, grouped by what they do. Each links to its own README and config.

### Substrate

| Plugin | Description |
|--------|-------------|
| [`ecosystem`](./) | Observability substrate: `$ONLOOKER_DIR` storage, canonical schema-validated event emission, session/tool tracking hooks, and prompt rules. The other plugins emit their events through it. |

### Memory & context

| Plugin | Description |
|--------|-------------|
| [`archivist`](./plugins/archivist) | Structured session memory across context truncation. Extracts decisions, dead ends, and open questions on `PreCompact`; reinjects the most relevant items at the next `SessionStart`. |
| [`librarian`](./plugins/librarian) | Consolidation layer between archivist's per-session artifacts and your durable typed memory store. Detects which decisions deserve to persist, classifies them, and queues proposals for explicit confirmation. |
| [`curator`](./plugins/curator) | Maintenance layer for the typed auto-memory store. Runs cheap heuristic checks (date-decayed, broken paths, orphaned entries) within a wall-clock budget and records what it finds, for a `/curator review` that has not shipped yet. Never edits memory directly. |
| [`historian`](./plugins/historian) | Episodic memory. Chunks and sanitizes the transcript at `SessionEnd`, then embeds each prompt on `UserPromptSubmit` to retrieve relevant past context. |
| [`scribe`](./plugins/scribe) | Intent documentation from agent activity. Captures *why* changes were made — problem context, decisions, tradeoffs — and distills them into readable artifacts at session end. |
| [`cartographer`](./plugins/cartographer) | Proactive auditor of the instruction layer (`CLAUDE.md`, `AGENTS.md`, `.claude/rules/`). Maps relationships and surfaces contradictions, dead rules, stale references, scope collisions, and undocumented entities before they cause misbehavior. |

### Quality & verification

| Plugin | Description |
|--------|-------------|
| [`tribunal`](./plugins/tribunal) | Multi-agent quality gates. Wraps a task in an Actor → Jury → Meta-Judge → Gate loop and retries the Actor with critique until the gate passes or `max_iterations` is reached. Grounded in LLM-as-a-Judge (Zheng et al. 2023) and LLM-as-a-Meta-Judge (Wu et al. 2024). Its Stop hook is opt-in. |
| [`echo`](./plugins/echo) | Measurement harness for LLM-as-judge evaluation of prompt-shaped files: measures whether a judge tells different inputs apart more reliably than it reproduces itself on the same input. Ships no hooks — the prompt-regression gate it used to run was retired as measured-ineffective. |
| [`assayer`](./plugins/assayer) | Claim verification. Parses the agent's final message for testable claims ("tests pass", "build is green") and checks each against the actual command results in the transcript. Catches lying-without-malice. Advisory only. |
| [`inspector`](./plugins/inspector) | Per-edit lint and typecheck gate. Runs the project's configured checks on just the touched file after every `Write`/`Edit`/`MultiEdit`, and on each file a `Bash` command changes, so the agent sees its own lint and type errors before claiming success. Cheaper than a full project verify; complements assayer. |

### Safety & alignment

| Plugin | Description |
|--------|-------------|
| [`compass`](./plugins/compass) | Pre-write intent clarity gate. Intercepts write-class tool calls and requires a confidence threshold before allowing them, evaluating the pending write against the prior assistant turn to avoid false positives on question-answer turns. |
| [`warden`](./plugins/warden) | Untrusted-content gate. Scans `WebFetch`/`Read` content for prompt-injection patterns and, on a hit, closes a session-scoped gate that blocks `Write`/`Edit`/`MultiEdit`/`Bash` until you clear it. Applies Meta's Agents Rule of Two by removing external actions while untrusted content is in play. |
| [`customs`](./plugins/customs) | Outbound secret gate. Before a `Bash` command or `WebFetch` URL leaves the machine, checks it for secret-shaped literals and asks when one is headed to a host that is not where that kind of secret goes. The counterpart to warden, which guards what comes in. |

### Cost & governance

| Plugin | Description |
|--------|-------------|
| [`governor`](./plugins/governor) | Resource governance and budget enforcement. Tracks per-session token and cost spend and gates `Task` spawns before they exceed a configurable ceiling. Named for the steam-engine governor that regulates output. |
| [`bursar`](./plugins/bursar) | Multi-session, per-project budget accounting. Rolls each session's spend into a per-project ledger on `SessionEnd` and surfaces "this project burned $X this week" at `SessionStart`. The cross-session rollup to governor's single-session view. |

### Observability & insight

| Plugin | Description |
|--------|-------------|
| [`lineage`](./plugins/lineage) | Per-change provenance — answers "why does this line exist?". Records session/turn metadata plus a redacted, size-capped snippet for every edit, whether made with an edit tool or a `Bash` command, then traces a file or line back to the change (and prompt) that introduced it. |
| [`counsel`](./plugins/counsel) | Weekly synthesis across the full observability stack. Reads every plugin's event log, produces a structured improvement brief, and injects it at session start when the last brief is stale. |

---

## Quick start

### Use it in Claude Code

Add the marketplace, then install the plugins you want:

```text
/plugin marketplace add onlooker-community/ecosystem
/plugin install ecosystem@onlooker-community
/plugin install inspector@onlooker-community
```

> Installation is through the marketplace only. `@onlooker-community/ecosystem`
> exists on npm for historical reasons and is deprecated — it carries no entry
> point and installs nothing. Nothing here is published to npm.

`ecosystem` is the substrate the other plugins emit their events through — install it first. Installing a plugin enables it; tune it under its namespace key in `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project). See [ADR-004](docs/adr/004-plugin-config-with-settings-overlay.md) for the configuration model.

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

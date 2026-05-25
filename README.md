# Onlooker Ecosystem

[![Test](https://github.com/onlooker-community/ecosystem/actions/workflows/test.yml/badge.svg)](https://github.com/onlooker-community/ecosystem/actions/workflows/test.yml)

Agents, skills, hooks, commands, rules, and MCP configurations that power [Onlooker](https://onlooker.dev).

The ecosystem is a **Claude Code plugin marketplace** built around a shared observability substrate. Every plugin writes to a common event log, derives stable project keys from your git remote, and stores artifacts under `~/.onlooker/` — so plugins compose without stepping on each other, and every event is queryable in one place.

---

## Plugins

| Plugin | Description | Opt-in? |
|--------|-------------|---------|
| [`ecosystem`](./) | Observability substrate: session tracking, canonical events, prompt rules, tool history. Required by all other plugins. | No — always on |
| [`archivist`](./plugins/archivist) | Structured session memory across context truncation. Extracts decisions, dead ends, and open questions; reinjects the most relevant items at the start of the next session. | Yes — disabled by default |
| [`tribunal`](./plugins/tribunal) | Multi-agent quality gates. Wraps a task in an Actor → Jury → Meta-Judge → Gate loop; retries the Actor with critique until the gate passes or `max_iterations` is reached. | Yes — skill always available; Stop hook opt-in |
| [`echo`](./plugins/echo) | Prompt-change regression detection. When a watched agent file is modified, runs a quality pass and reports whether the change improved, degraded, or had no measurable effect. | Yes — disabled by default |

For how these fit together, see [docs/architecture.md](docs/architecture.md).

---

## Quick start

```bash
# Install the Onlooker CLI
brew tap onlooker-community/tap
brew install onlooker

# Run the guided setup wizard
onlooker setup
```

---

## Development

Install tools with [mise](https://mise.jdx.dev/) (`mise install`), then install dependencies:

```bash
npm ci
npm test                # bats + schema validation tests
npm run test:shellcheck
npm run test:ci         # shellcheck + bats + schema + lint
```

Hooks emit [canonical Onlooker events](https://github.com/onlooker-community/schema) via `scripts/lib/onlooker-event.mjs`. Bash helpers live in `scripts/lib/`.

Tests live under `test/bats/` and `test/node/` and use an isolated temp home so nothing writes to your real `~/.onlooker/`.

---

## Prompt rules

The ecosystem plugin ships a `UserPromptSubmit` hook that injects declarative guidance when a user prompt matches a regex. Rules fire deterministically on literal prompt-text patterns, filling the niche that skills can't: guidance that must fire regardless of whether the model would have chosen a skill.

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

# Onlooker Ecosystem

[![Test](https://github.com/onlooker-community/ecosystem/actions/workflows/test.yml/badge.svg)](https://github.com/onlooker-community/ecosystem/actions/workflows/test.yml)

Agents, skills, hooks, commands, rules, and MCP configurations that power [Onlooker](https://onlooker.dev).

---

## Development

Install tools with [mise](https://mise.jdx.dev/) (`mise install`), then install dependencies (includes [`@onlooker-community/schema`](https://www.npmjs.com/package/@onlooker-community/schema) from npm):

```bash
npm ci
npm test              # bats + schema validation tests
npm run test:shellcheck
npm run test:ci       # shellcheck + bats + schema + lint
```

Hooks emit [canonical Onlooker events](https://github.com/onlooker-community/schema) via `scripts/lib/onlooker-event.mjs`. Bash helpers live in `scripts/lib/onlooker-schema.sh`.

Tests live under `test/bats/` and `test/node/` and use an isolated temp home so nothing writes to your real `~/.onlooker`.

## Quick Start

Get up and running in under 2 minutes:

```bash
# Use homebrew to install Onlooker client
brew tap onlooker-community/tap
brew install onlooker

# Use the wizard to be guided through setup
onlooker setup
```

## Marketplace plugins

This repository is a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`). The default plugin, `ecosystem`, lives at the repo root and provides the observability substrate every other plugin in this marketplace builds on. Additional plugins live under `plugins/<name>/` and depend on `ecosystem` being installed.

| Plugin | Location | Status |
|---|---|---|
| `ecosystem` | `./` | Default — Onlooker observability hooks and canonical events |
| [`archivist`](./plugins/archivist) | `./plugins/archivist` | Structured session memory across context truncation |

## Prompt rules

The ecosystem plugin ships a `UserPromptSubmit` hook (`scripts/hooks/prompt-rule-injector.sh`) that injects declarative guidance when a user prompt matches a regex you define. It fills the niche skills can't: deterministic firing on a literal prompt-text pattern, regardless of whether the model would have picked a skill from its description.

Rules live in two files:

- `~/.onlooker/prompt-rules.json` — global, applies across projects
- `<repo>/.claude/prompt-rules.json` — project, overrides global by `id`

```json
{
  "rules": [
    {
      "id": "rule-no-verify-warning",
      "pattern": "--no-verify",
      "guidance": "Skipping hooks usually masks the real issue. Investigate the failure first.",
      "fire_once_per_session": true,
      "max_chars": 400,
      "enabled": true,
      "tags": ["safety"]
    }
  ]
}
```

`pattern` is POSIX ERE (bash `[[ =~ ]]` semantics). `\b` is unsupported — use character classes like `(^|[^a-zA-Z0-9_])foo([^a-zA-Z0-9_]|$)` for word-boundary behavior.

Each rule fires at most once per session per `id`. Markers live at `~/.onlooker/prompt-rules/sessions/<session_id>.json`. The hook emits `prompt_rule.matched` and `prompt_rule.applied` events to `~/.onlooker/logs/onlooker-events.jsonl`. Run `/list-prompt-rules` to see active rules and per-session fire state.

Configurable knobs in `config.json` under `prompt_rules`:

- `enabled` (default `true`)
- `per_turn_max_chars` (default `1200`) — hard ceiling on injected guidance per prompt
- `max_rules` (default `50`) — soft guidance; not enforced in v1

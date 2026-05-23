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

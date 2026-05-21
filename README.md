# Onlooker Ecosystem

Agents, skills, hooks, commands, rules, and MCP configurations that power [Onlooker](https://onlooker.dev).

---

## Development

Install tools with [mise](https://mise.jdx.dev/) (`mise install`), then:

```bash
npm ci
npm test              # bats integration tests
npm run test:shellcheck
npm run test:ci       # shellcheck + tests + lint
```

Tests live under `test/bats/` and use an isolated temp home so nothing writes to your real `~/.onlooker`.

## Quick Start

Get up and running in under 2 minutes:

```bash
# Use homebrew to install Onlooker client
brew tap onlooker-community/tap
brew install onlooker

# Use the wizard to be guided through setup
onlooker setup
```

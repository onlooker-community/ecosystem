# Copilot review guidance for the Onlooker ecosystem

This file shapes Copilot's review comments and chat suggestions. Keep it tight and prescriptive — Copilot weights every line.

## Repository shape

This is a Claude Code plugin marketplace, not a typical npm package. The default plugin (`ecosystem`) lives at the repo root and provides the observability substrate; sibling plugins live under `plugins/<name>/` and assume `~/.onlooker/` exists. Every sibling plugin has its own `.claude-plugin/plugin.json` and may have its own `hooks/hooks.json` and `scripts/`.

When reviewing changes:

* Treat `marketplace.json` and per-plugin `plugin.json` as governed by [Claude Code's plugin schema](https://code.claude.com/docs/en/plugins-reference). `version` belongs in `plugin.json` only — never in marketplace entries. Flag any PR that puts `version` on `marketplace.json plugins[]`.
* `scripts/lint/check-manifests.mjs` and `scripts/lint/check-references.mjs` are the source of truth for what's "valid." If a PR seems to violate a manifest invariant, point at those linters.
* Hooks must never block the host session. They exit 0 even on internal error, and they log failures to `~/.onlooker/logs/hook-health.jsonl` instead of throwing.

## Locking, concurrency, portability

* Cross-process file locking goes through `lock_acquire` / `lock_release` in `scripts/lib/portable-lock.sh`. **Do not introduce new `flock` calls** — mkdir-based mutex is the convention because the hooks run on macOS without util-linux.
* Avoid bash 4+ features (associative arrays especially). macOS ships bash 3.2 by default and the hooks need to run there.
* Hooks use `set -uo pipefail`, not `set -e`. Failing fast in a hook is worse than degrading gracefully.

## Style + tooling

* American English everywhere — commits, comments, identifiers, docs. (`color`, `behavior`, `normalize`, `analyze`.)
* Conventional Commits with a mood emoji that reflects *this* change, not the type label. Don't mechanically pair `feat: :sparkles:` or `fix: :bug:`.
* Lint stack: `biome` (JS), `shellcheck -S error -x` (bash), `markdownlint` (md). Add new shell files to the `test:shellcheck` script.
* Tests live under `test/bats/` (shell) and `test/node/` (mjs, using `node:test`). Every new helper function deserves a bats test by name — `scripts/coverage/bash-coverage.mjs` measures this and surfaces it in the PR coverage comment.
* No new runtime deps without a paragraph in the PR explaining why a stdlib-only solution doesn't fit. The validators are deliberately dependency-free.

## Things that almost always indicate a bug

* A hook that returns non-zero on its happy path.
* A bash function definition not at column 0 (the coverage analyzer assumes top-level only).
* A markdown skill/command/agent missing `name` and `description` frontmatter (the reference linter will fail).
* A new plugin without an entry in `marketplace.json` (or with one carrying a `version` field).
* `git config --global` calls in scripts or workflows (we never want to mutate the developer's signing/auth setup).
* Writes to `~/.onlooker/` that don't honor `$ONLOOKER_DIR` overrides (breaks bats isolation).

## Release flow

`release-please` drives versioning. Each plugin's `plugin.json.version` is bumped from its own commit history; `marketplace.json` is *not* version-bumped. `release.yml` only publishes the root ecosystem package to npm — sibling plugins are distributed via the marketplace, not npm.

## What to focus on in reviews

In order of importance: correctness over elegance, smallest-possible-diff over architectural rewrites, evidence of testing (especially: did the PR add a bats test, a node test, or update fixtures?), and naming hygiene (kebab-case for plugin/command/skill names; snake_case for bash functions; camelCase for JS).

When in doubt about a convention, say so explicitly rather than guessing.

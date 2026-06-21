# ADR-005: The Runtime Emitter Is Dependency-Free and Fails Open

**Status:** Accepted  
**Date:** 2026-06-20  
**Amends:** [ADR-002](002-centralized-jsonl-event-log.md)

## Context

The canonical emitter `scripts/lib/onlooker-event.mjs` built each event envelope and **validated it against `@onlooker-community/schema` before printing it** (ADR-002: "schema validation at write time prevents silent corruption"). `@onlooker-community/schema` was a runtime `dependency`, and it pulls in `ajv` + `ajv-formats`. The package also reads its JSON schema files from disk at import time.

This assumed `node_modules` would be present wherever a hook runs. It is not. **Claude Code installs a marketplace plugin by cloning the marketplace repo; it never runs `npm install`.** `node_modules/` is git-ignored, so the installed plugin ships none. Every emission therefore ran:

```
node scripts/lib/onlooker-event.mjs emit
  └─ import '@onlooker-community/schema'  →  ERR_MODULE_NOT_FOUND  →  exit 1
```

The bash side of each hook kept working (hook-health, per-session trackers need no node), so hooks looked healthy while **every event was silently dropped**. In one observed case `~/.onlooker/logs/onlooker-events.jsonl` received nothing for 18 days. Fail-closed validation, intended to prevent "silent corruption," instead produced total silent loss — a strictly worse failure than the one it guarded against.

Mechanisms considered to make the dependency available in the install: vendor a committed `node_modules`, bundle the emitter + `ajv` into one file with esbuild, or a self-healing `SessionStart` hook that runs `npm install`. Each ships or fetches a validator with the plugin and carries cost (repo bloat, a build step, or a network dependency on every fresh install).

## Decision

**The runtime emitter has zero external dependencies and fails open.** Validation is best-effort, not a gate:

- `createEvent` (envelope assembly) and the event-type constants are **inlined** into `onlooker-event.mjs` — pure `node:` stdlib, no package import.
- Validation is attempted via a lazy `await import('@onlooker-community/schema')`. When the package resolves (dev, CI, tests) the emitter validates and **rejects** invalid events. When it does not resolve (installed plugins) the emitter **emits anyway**.
- `@onlooker-community/schema` moves from `dependencies` to `devDependencies`.
- A CI test (`test/node/schema-published.test.mjs`) validates representative emitter output against the canonical schemas **published at `https://schema.onlooker.dev`** — the contract downstream consumers actually enforce. It skips when the endpoint is unreachable.

## Rationale

**Observability must not be fragile.** A telemetry pipeline that deletes everything when a dependency is missing — or when a payload drifts from the schema — is worse than one that records a slightly-off event. For an observability substrate, fail-open is the correct default: capture the signal, surface problems out-of-band.

**Best-effort keeps the dev-time guard.** The same lazy import that degrades gracefully in production still gates strictly wherever the validator is installed. The negative tests across the plugins ("emission fails loudly on a bogus event_type") keep passing because CI runs with dev dependencies present. We lose nothing in the loop that catches mistakes, and gain resilience where mistakes are unrecoverable.

**Validation belongs where it can act, not on the hot path.** A hook firing on every tool call cannot meaningfully respond to a validation failure except by dropping data. CI can: a red test blocks the release. Moving the authoritative check to CI — against the *published* schemas, not just the pinned npm copy — catches drift between what the emitter produces and what the deployed contract accepts.

**No artifact to ship or fetch.** Dependency-free is simpler than vendoring a `node_modules`, bundling with esbuild, or bootstrapping `npm install` at session start. There is nothing to keep in sync, nothing to build, and the install works offline.

## Consequences

- The JSONL log may, in an installed plugin, contain an event that violates the schema if a payload builder drifts. Downstream consumers (the onlooker agent, the backend) validate on ingest; CI catches drift before release. This is the accepted cost of fail-open.
- `node` is still required to emit (the emitter is JS), but **no npm packages are**. Hooks that shell out to `onlooker-event.mjs` work on a fresh clone with nothing installed.
- The `validate` CLI subcommand and `onlooker_validate_event` still require the dev dependency; they are used only by the test suite, never on a runtime hook path.
- `test:schema` now makes a network call to `schema.onlooker.dev`. It skips cleanly offline, so local and air-gapped runs are unaffected; CI with egress exercises the live contract.

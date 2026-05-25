# ADR-002: Centralized JSONL Event Log with Schema Validation

**Status:** Accepted  
**Date:** 2026-05-24

## Context

Every plugin produces structured signals — session timings, Tribunal verdicts, Echo drift scores, Archivist extraction events. These signals need to be stored somewhere. Options considered:

- **Per-plugin flat files** — each plugin writes its own log in its own format.
- **SQLite database** — a structured store under `~/.onlooker/`.
- **Centralized JSONL log** — all plugins append to a single `~/.onlooker/logs/onlooker-events.jsonl` file, with a schema-validated envelope per event.
- **Remote backend only** — events are sent directly to a cloud endpoint; nothing stored locally.

## Decision

All schema-defined events are written to a **centralized JSONL log** at `~/.onlooker/logs/onlooker-events.jsonl`, validated against [`@onlooker-community/schema`](https://github.com/onlooker-community/schema) before write. The log may also contain non-schema events from hooks that predate or have not yet been ported to the canonical pipeline (see Consequences).

## Rationale

**One place to query.** A single log means a dashboard, script, or downstream consumer can read everything without knowing which plugins are installed or where each one writes. Cross-plugin queries (e.g., "show Tribunal verdicts alongside the Echo drift scores for the same session") require no joins across separate stores.

**JSONL is the simplest durable format.** One JSON object per line. Human-readable with `jq`. Appendable without locking (each `printf '%s\n'` is atomic on POSIX filesystems for lines under the page size). No schema migrations, no vacuum, no connection management.

**Schema validation at write time prevents silent corruption.** Each event is validated before it is appended. If a plugin emits a malformed payload, the write fails loudly — the hook logs an error and the line is never added to the log. This means the log is always a valid, queryable dataset. Per-plugin flat files with ad-hoc formats would accumulate inconsistencies silently.

**Versioned schema as a contract.** The schema is published as `@onlooker-community/schema` on npm and versioned independently. Plugins declare which schema version they target. When the schema adds new event types (e.g., the `echo.*` events added in v2.2.0), old plugins continue to work — they just don't emit the new types. Consumers can use the schema version field to handle evolution.

**Local-first for privacy.** All data stays on the developer's machine by default. A future cloud-sync feature can read the JSONL and upload selectively; the log itself makes no network calls.

## Why not SQLite?

SQLite would give us structured queries, indexes, and transactions. The tradeoff is operational complexity: the file has a binary format (not inspectable with `cat`/`jq`), requires a SQLite binary, and has locking behavior that could deadlock if multiple hook processes fire concurrently. JSONL with append-only writes has no locking issue and is trivially inspectable.

## Consequences

- The log grows indefinitely. A future rotation/archival feature is needed for long-lived developer machines. Currently operators must prune manually.
- The goal is that all event types are defined in `@onlooker-community/schema` before a plugin emits them. Adding a new event type requires a schema release — intentional friction that prevents undocumented shapes from accumulating. In practice, `prompt_rule.*` events are a current exception: they are emitted to the log by the prompt-rules hook but are not yet defined in the schema. This should be resolved in a future schema release.
- Concurrent appends from multiple hooks (e.g., a `PostToolUse` hook and a `Stop` hook firing close together) are safe for lines under ~4 KB on POSIX, but multi-kilobyte payloads could interleave. In practice, event payloads are small and this has not been an issue.

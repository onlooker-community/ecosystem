# ADR-003: At-Least-Once Event Delivery with finding_hash Deduplication

**Status:** Accepted

## Context

Cartographer emits `cartographer.issue.found` events for new findings, then writes a sentinel file to `dedup/<hash>` to mark them as known. If the process crashes between the event emission and the sentinel write, the same finding is re-emitted on the next audit run.

We must choose between:
- **Exactly-once:** write sentinel first, then emit event. If the process crashes after writing the sentinel but before emitting, the event is permanently lost.
- **At-least-once:** emit event first, then write sentinel. If the process crashes between, the event is re-emitted once on the next run.

## Decision

Use **at-least-once delivery**. Findings carry a `finding_hash` in their event payload. Downstream consumers (event log aggregators, Linear integrations, dashboards) must deduplicate on `payload.finding_hash` in their own stores.

**Rationale:** A missed finding (exactly-once failure) silently suppresses a real issue. A duplicate finding (at-least-once failure) is visible and correctable. For an advisory tool, false negatives are worse than false positives.

**At-most-once per process run** is still guaranteed: within a single `run-audit.sh` invocation, the dedup sentinel is checked before emitting, so the same finding is emitted at most once per run.

The delivery contract is documented in SKILL.md and the plugin CLAUDE.md.

## Consequences

- Downstream consumers must implement `finding_hash`-keyed deduplication.
- A crash during `run_emit` will re-emit at most N findings on the next run (where N is the number of new findings after the crash point).
- The behavior is deterministic: re-emissions carry the same `finding_hash` as the original, so dedup is always possible.

## Alternatives Considered

- **Write-then-emit (exactly-once attempt):** Simpler logic, but loses findings on crash. Unacceptable for an advisory auditor.
- **Two-phase commit (journal):** Write an intent log, emit, mark complete. Correct but complex for a shell script; deferred to v0.2 if needed.

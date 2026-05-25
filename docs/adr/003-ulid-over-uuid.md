# ADR-003: ULID for All Identifiers

**Status:** Accepted  
**Date:** 2026-05-24

## Context

Every artifact in the ecosystem — Archivist memories, Tribunal tasks and iterations, Echo suites and tests — needs a unique identifier. The identifier is used as a filename, a log correlation key, and a sort key. Options considered:

- **UUID v4** — random, universally supported, 36 chars with hyphens.
- **UUID v7** — time-ordered UUID, requires a library on older runtimes.
- **ULID** — Universally Unique Lexicographically Sortable Identifier. 26 chars, Crockford Base32, time-ordered to millisecond precision.
- **Timestamp + random suffix** — ad-hoc, human-readable but not globally unique.
- **Sequential integer** — simple but requires a counter store and fails across processes.

## Decision

All ecosystem identifiers use **ULID**.

## Rationale

**Lexicographically sortable = chronologically sortable.** ULIDs sort correctly with `ls`, `sort`, and JSONL readers without parsing a timestamp field. Artifact directories and log entries naturally order by creation time. With UUID v4, sorting by filename requires a separate `created_at` index.

**No hyphens, no special characters.** ULIDs use Crockford Base32 (characters `0-9A-Z` excluding `I`, `L`, `O`, `U`). They are safe in filenames, URLs, and environment variables without quoting or encoding. UUID hyphens require quoting in some shell contexts.

**Compact.** 26 characters vs. 36 for UUID. Minor, but it matters in log lines and filenames that appear in terminal output.

**Millisecond time prefix enables time-range queries.** The first 10 characters of a ULID encode the Unix timestamp in milliseconds. A script can filter the JSONL log to a time range by string-comparing ULID prefixes without parsing every `timestamp` field.

**No runtime dependency.** Each plugin ships its own `echo-ulid.sh` / `archivist-ulid.sh` / `tribunal-ulid.sh` generator implemented in pure bash (with a `python3` fallback for millisecond timestamps on macOS, where `date +%s%3N` is broken). No UUID library needed.

## Why not UUID v7?

UUID v7 is time-ordered like ULID but uses the standard UUID format (32 hex + 4 hyphens). The tradeoffs vs. ULID are: more characters, hyphen special-casing in filenames, and no widely available pure-bash generator. ULID is the better fit for a shell-first ecosystem.

## Consequences

- Every plugin that generates IDs ships its own `*-ulid.sh` library. This is intentional duplication to avoid cross-plugin runtime dependencies, but it means ULID generation logic exists in three places. All three are tested identically via bats.
- ULID has 80 bits of randomness in the lower 80 bits (after the 48-bit timestamp). The collision probability is negligible for the volumes this ecosystem handles, but not zero.
- The time-ordered property is only guaranteed within a single millisecond. ULIDs generated in the same millisecond are random in the lower bits, so their relative order is not deterministic. This is acceptable — within a session, events are ordered by emission, not by ULID sort.

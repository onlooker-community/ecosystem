# Bounding the Onlooker store

**Date:** 2026-08-30
**Tracking:** `ecosystem-449.2`
**Status:** Design approved, implementation pending

## Problem

`~/.onlooker` is 825MB. The bead that filed this read the symptom as unbounded
accumulation and proposed a retention window. Measurement says the cause is
something else, and a retention window barely touches it.

Across the five per-session stores:

| Store | Files | Logical | On disk | Waste |
|---|---:|---:|---:|---:|
| `session-trackers` | 37,571 | 15.4M | 153.9M | 138.5M |
| `session-history` | 33,135 | 40.7M | 151.3M | 110.6M |
| `scribe/sessions` | 37,403 | 17.8M | 153.2M | 135.4M |
| `bursar/sessions` | 31,720 | 4.8M | 129.9M | 125.1M |
| `compass/sessions` | 10,896 | 3.5M | 45.9M | 42.4M |
| **Total** | **150,725** | **82.2M** | **634.2M** | **551.9M** |

**87% of the on-disk footprint is filesystem block waste.** The files average
545 bytes; each one consumes a 4KB block. The store does not hold 634MB of
data. It holds 82MB of data in 150,725 files.

Two measurements name the real problem:

* **65% of scribe's files carry no payload at all.** 24,397 of 37,403 contain
  exactly `{"session_id": …, "captured_prompt": null, "captured_at": null}` —
  100MB of blocks holding zero information.
* **93% of `session-history` files hold two lines or fewer.** 30,853 files, one
  4KB block each.

The driver is session-id cardinality. Every subagent spawn gets its own session
id, so every subagent gets its own tracker, scribe state file, and bursar
record. A heavy multi-agent day mints tens of thousands of near-empty files. The
mtime histogram shows this directly: ordinary days produce 1–20 files, while
2026-07-26 produced 36,751 and 2026-08-07 produced 34,974.

### Why retention is the wrong instrument

Modeled against the real data:

| Window | Files deleted | Reclaimed |
|---|---:|---:|
| 90 days | 47 | 1.9MB (0%) |
| 60 days | 31,746 | 133.5MB (21%) |
| 30 days | 84,069 | 348.0MB (55%) |

A 90-day policy reclaims 1.9MB of 634MB. Reaching a meaningful number requires a
window short enough to delete recent, wanted data — and it would still leave the
write path minting a 4KB block per empty file. Retention treats the symptom.

## Approach

Fix the write path so the garbage is never written, prune the existing backlog
once, and add a cheap recurring sweep as a backstop. Explicitly **not** in scope:
consolidating the per-session stores into append-only per-day logs. That is the
larger win (~550MB) but it changes four plugins' storage formats and their
lookup-by-session-id read paths — the substrate refactor the dogfooding rollout
design warns against coupling to the waves. Filed separately.

### 1. scribe stops writing empty state files

`scribe-session-start.sh` drops its eager state-file write and keeps only the
`mkdir -p` of the storage directory.

This is safe because the two consumers already handle absence:

* `scribe-capture.sh` has a create-if-missing branch that writes the full
  payload on the first real prompt.
* `scribe-distill.sh` guards its read with `[[ -f "$state_file" ]]` and falls
  back to an empty `captured_prompt`.

No file exists until there is a prompt to record. As a side effect this removes
one `jq` invocation from the `SessionStart` path.

### 2. A deferred sweep, not deletion at SessionEnd

The obvious fix for `session-trackers` — delete the tracker when its session ends
— is a bug. `bursar-session-end.sh:55` reads
`session-trackers/$SESSION_ID`, and hooks within one `hooks` array run in
parallel. Deleting from ecosystem's `SessionEnd` hook races bursar and silently
corrupts its spend rollup.

Trackers therefore age out on a window (default 48h) rather than being deleted
at end of session. No cross-plugin hook ordering to get right, and an in-flight
session is never touched because its tracker is by definition recent.

### 3. Two components

The backlog and the steady state need different tools. 150,725 deletions cannot
happen inside a hook with a 1.5s budget.

**One-shot — `scripts/onlooker-store-prune.mjs`.** Run manually. No time budget.
Handles the existing backlog, reports before/after counts and bytes. It applies
the same windows as the recurring sweep, plus one rule the sweep does not need:

* **Payload-free scribe state files are deleted regardless of age.** A file whose
  `captured_prompt` is `null` carries zero information, so age is irrelevant to
  whether it is worth keeping. This is what reclaims the 24,397 existing empty
  files (100MB); the write-path fix in §1 only prevents new ones.

Nothing modified inside its store's window is touched, which is what keeps
in-flight sessions safe.

**Recurring — `scripts/hooks/storage-gc.sh`, on `SessionEnd`.** A stamp file at
`$ONLOOKER_DIR/.gc-stamp` gates it to once per 24h; when the stamp is fresh the
hook exits immediately. Otherwise it sweeps under a wall-clock budget well
inside `SessionEnd`'s 1.5s. It only ever has to keep up with one day's delta.

`SessionEnd` rather than `SessionStart` deliberately: `SessionStart` is already
265ms and is one of the numbers the dogfooding waves are measuring.

### 4. What GC touches

| Store | Policy |
|---|---|
| `session-trackers` | 48h (scratch) |
| `session-history`, `scribe/sessions`, `bursar/sessions`, `compass/sessions` | 90 days |
| historian, lineage, archivist, librarian, curator | never — durable memory |
| `buffer.db` | never — see below |

Config lives in `config.json` under `ecosystem.storage.gc`, honoring
`$ONLOOKER_DIR` so the test suite's isolated temp home is respected:

```json
{
  "storage": {
    "gc": {
      "enabled": true,
      "interval_hours": 24,
      "budget_ms": 1000,
      "scratch_max_age_hours": 48,
      "retention_days": 90
    }
  }
}
```

Both components fail soft. A missing `~/.onlooker`, an unreadable directory, or
a blown budget ends the sweep without an error and without blocking the session.

### 5. Out of scope, filed separately

* **Consolidation to per-day append-only logs.** The ~550MB win. Deferred until
  after the dogfooding waves so it does not confound their measurements.
* **`buffer.db` — 112MB, 115,520 rows, plus a 9MB WAL.** No script, hook, or
  config in this repo reads or writes it. GC must not touch a store it cannot
  identify; its owner needs tracing first.
* **historian's dead `retention_days`.** `plugins/historian/config.json` declares
  `retention_days: 365` and nothing reads it. A knob that does nothing is worse
  than no knob.

## Testing

Bats, against `test/helpers/setup.bash`'s isolated temp home:

* GC exits fast when the stamp is fresh, sweeps when it is stale.
* Scratch older than the window is pruned; scratch inside it survives.
* Durable stores are untouched by a sweep that prunes everything else.
* `$ONLOOKER_DIR` is honored — a sweep against a temp home never reads `$HOME`.
* The one-shot prune skips recently modified files.
* The one-shot prune deletes a payload-free scribe file but keeps one that has a
  `captured_prompt`, even when both are the same age.
* Regression: `scribe-session-start.sh` creates no state file, and
  `scribe-capture.sh` still creates one with a full payload on first prompt.

New event types (`ecosystem.gc.completed`, `ecosystem.gc.skipped`) are registered
in `@onlooker-community/schema` before emission and triaged into
`test/bus-coverage.json`, per the plugin checklist.

## Expected result

~254MB reclaimed, both worst producers bounded at the source, and no plugin's
storage format changed — so the dogfooding waves stay attributable.

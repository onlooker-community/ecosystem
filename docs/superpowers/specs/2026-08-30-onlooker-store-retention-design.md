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

Fix the write path so the garbage is never written, and prune the existing
backlog once with a script run by hand. Explicitly **not** in scope:
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

### 2. Age out scratch, never delete it at SessionEnd

The obvious fix for `session-trackers` — delete the tracker when its session ends
— is a bug. `bursar-session-end.sh:55` reads
`session-trackers/$SESSION_ID`, and hooks within one `hooks` array run in
parallel. Deleting from ecosystem's `SessionEnd` hook races bursar and silently
corrupts its spend rollup.

Trackers therefore age out on a window (default 48h) rather than being deleted
at end of session. No cross-plugin hook ordering to get right, and an in-flight
session is never touched because its tracker is by definition recent.

### 3. One component, run by hand

**`scripts/onlooker-store-prune.mjs`.** Run manually. No time budget. Applies the
windows in §4, reports before/after counts and bytes, plus one rule that is not
about age at all:

* **Payload-free scribe state files are deleted regardless of age.** A file whose
  `captured_prompt` is `null` carries zero information, so age is irrelevant to
  whether it is worth keeping. This is what reclaims the 24,397 existing empty
  files (100MB); the write-path fix in §1 only prevents new ones.

Nothing modified inside its store's window is touched, which is what keeps
in-flight sessions safe.

A recurring sweep to keep the store bounded without anyone remembering to run
this was designed and then deliberately cut — see §5. The consequence to accept
is that between runs nothing enforces the windows, so §1 is doing the real work
of keeping growth bounded and this script is a periodic reset.

### 4. What the prune touches

| Store | Policy |
|---|---|
| `session-trackers` | 48h (scratch) |
| `session-history`, `scribe/sessions`, `bursar/sessions`, `compass/sessions` | 90 days |
| historian, lineage, archivist, librarian, curator | never — durable memory |
| `buffer.db` | never — see below |

The windows are flags with these defaults — `--scratch-max-age-hours 48`,
`--retention-days 90` — rather than a `config.json` block. Nothing reads config
here yet, and a settings key whose only consumer is a script you invoke by hand
is a knob that mostly exists to drift. The recurring sweep in §5 is what would
justify persisting them; it can add the block when it lands.

The script honors `$ONLOOKER_DIR` so the test suite's isolated temp home is
respected, and fails soft: a missing `~/.onlooker` or an unreadable directory
ends the run with a report and a zero exit, not an error.

### 5. Out of scope, filed separately

* **The recurring sweep** (`ecosystem-ave`). A `storage-gc.sh` on `SessionEnd`, stamp-gated to once
  per 24h and budgeted well inside `SessionEnd`'s 1.5s, is what would keep the
  store bounded without anyone remembering to run §3. Cut from this work on
  purpose: wave 1 is about to characterize `SessionEnd` latency, and a new hook
  on that cadence — even one that fast-exits 24 hours out of 25 — is a variable
  in the measurement it would land in the middle of. Revisit after wave 1.
* **Consolidation to per-day append-only logs** (`ecosystem-c95`). The ~550MB win. Deferred until
  after the dogfooding waves so it does not confound their measurements.
* **`buffer.db`** (`ecosystem-s6f`) — 112MB, 115,520 rows, plus a 9MB WAL. No script, hook, or
  config in this repo reads or writes it. GC must not touch a store it cannot
  identify; its owner needs tracing first.
* **historian's dead `retention_days`** (`ecosystem-d8j`). `plugins/historian/config.json` declares
  `retention_days: 365` and nothing reads it. A knob that does nothing is worse
  than no knob.

## Testing

Against `test/helpers/setup.bash`'s isolated temp home:

* Scratch older than the window is pruned; scratch inside it survives.
* Durable stores are untouched by a run that prunes everything else.
* `$ONLOOKER_DIR` is honored — a run against a temp home never reads `$HOME`.
* A payload-free scribe file is deleted but one with a `captured_prompt` is kept,
  even when both are the same age.
* Recently modified files are skipped, which is the in-flight-session guarantee.
* Regression, in bats: `scribe-session-start.sh` creates no state file, and
  `scribe-capture.sh` still creates one with a full payload on first prompt.

No new event types. Emission was tied to the recurring sweep, so nothing needs
registering in `@onlooker-community/schema` or triaging into
`test/bus-coverage.json` for this work.

## Expected result

~254MB reclaimed, the two worst producers bounded at the source, no plugin's
storage format changed, and no new hook on any cadence — so the dogfooding waves
stay attributable.

What this does not deliver is the "enforced" half of the bead's acceptance
criteria. §1 enforces bounded creation permanently, but with the recurring sweep
cut, nothing applies the windows on a schedule; §3 is a reset you run. Closing
that gap is the follow-up bead, after wave 1.

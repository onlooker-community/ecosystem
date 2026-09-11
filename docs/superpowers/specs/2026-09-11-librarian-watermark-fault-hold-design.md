# Holding librarian's watermark through a marker fault

**Date:** 2026-09-11
**Tracking:** `ecosystem-449.55` (under epic `ecosystem-449`)
**Status:** designed

## Problem

`librarian_storage_write_last_scan` writes the current time, unconditionally. It takes no
timestamp argument — the value is always `now`:

```sh
# librarian-storage.sh:140-148
librarian_storage_write_last_scan() {
	local key="$1"
	...
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	jq -n --arg t "$now" '{ scanned_at: $t }' > "$path" 2>/dev/null
}
```

`librarian_archivist_load_since` then filters artifacts by their own `created_at` against that
value, skipping anything at or before it. So the watermark is read as *"everything up to here
has been handled"* while it only ever records *"this is when I last ran"*. A scan that **ran**
but did not **judge** its window advances the cursor as though it had, and the window is gone.

That is not hypothetical. During the outage recorded in `ecosystem-449.48`, the durability
allowlist was empty, so every artifact clearing the length gate was dropped. The watermark
advanced on each of those scans:

| Measured | Value |
|---|---|
| Drops recovered from `~/.onlooker/buffer.db` | 3,837 |
| Distinct drop reasons among them | 1 (`filter_marker_missing`, 100%) |
| Window | 2026-08-01T23:10Z – 2026-08-03T16:28Z |
| Recoverable through the normal pipeline today | 0 |

Fixing the filter (`#313`) does not bring them back. They sit behind the watermark, and
`load_since` will never offer them again.

## Scope decisions

**Configuration faults only, not a general invariant.** The obviously tempting fix is one rule
— *advance only past artifacts you actually judged* — which would also repair the
budget-exceeded path. That is deliberately **not** this design. It changes what the watermark
means for every exit path, and the narrow fix buys the recovery that matters without that
blast radius. The general defect is filed separately.

**`:197` is still guarded, and this is not a budget fix.** The budget-exceeded bail advances
the watermark at `:197`. The hold flag is a property of *this scan*, so it has to be honored
wherever the scan exits — otherwise the hold leaks through the budget path at exactly the
moment the backlog is largest and `load_since` is slowest. Guarding `:197` with the fault flag
does not change its behavior for any non-fault scan, and its independent defect stays open.

**`:144` is untouched.** It is upstream of the filter. An empty window contains no artifacts,
so there is nothing to lose and no fault to detect.

**Bounded, and loud when the bound is hit.** A persistent misconfiguration grows the window
every session, and `load_since` forks `jq` once per artifact file, so an unbounded hold
degrades SessionEnd until the budget path fires and discards the backlog anyway. The invariant
worth protecting is not *never lose artifacts* — it is **never lose them silently**. Past the
ceiling the scan abandons the backlog and says so, per artifact.

## Design

### The flag

After the durability filter, count the drops whose reason is `filter_markers_unavailable`.
Compute one flag, consulted at every watermark write below the filter:

| Condition | Behavior |
|---|---|
| no fault drops | advance — unchanged from today |
| fault drops, window `<` ceiling | **hold** |
| fault drops, window `>=` ceiling | advance, reporting the drops as `retry_cap_exceeded` |

The ceiling compares against the whole window rather than the fault-drop count, because what
is being bounded is the repeated `load_since` walk, and that walk reads every artifact in the
window regardless of how each one was later classified.

`retry_cap_exceeded` **replaces** `filter_markers_unavailable` on those drops rather than
adding a second event per artifact. Both facts are true — the markers were missing, and the
artifact is being abandoned — but only one of them is terminal, and the terminal one is what a
reader needs. The events reuse the existing `librarian.candidate.dropped` type and the existing
`MAX_DROPPED_EVENTS=20` per-scan cap, so a large abandoned backlog cannot flood the log.

### Configuration

`.librarian.scan.max_fault_retry_artifacts`, read alongside `min_detail_chars`.

**Default 500.** A judgment call, stated so it can be argued with: ordinary windows hold a
handful of artifacts, and the observed outage accumulated 3,837 over roughly two months. 500
holds about three weeks at that rate while keeping the repeated `load_since` walk bounded.

### Schema

`retry_cap_exceeded` is a new value on the `librarian.candidate.dropped` reason enum in
`@onlooker-community/schema`. The payload is `additionalProperties: false` with closed enums,
so there is no way to express this without a schema change; it ships first, then the ecosystem
lockfile bumps.

The ordering should be self-enforcing rather than something to remember, and it is not yet. The
reconciliation test added in `#314` greps reason literals out of `librarian-durability.sh`
only — but `retry_cap_exceeded` is assigned in the hook, so that test would not see it. The
same blind spot already covers three live reasons the hook emits today (`classified_null`,
`duplicate`, `low_confidence`); all three happen to be in the enum, so nothing is currently
broken, but the guard is narrower than it appears.

Widening the test to scan `librarian-session-end.sh` as well as the filter is therefore part of
this work, and lands **before** the new literal. With that in place, adding a reason ahead of
its schema value fails the suite by construction.

## What this does and does not recover

**It does not recover the 3,837.** They are already behind the watermark, and nothing in this
design reaches backward.

**It would not have caught the original outage as it actually occurred**, and this is worth
stating plainly rather than discovering later. Those drops carry `filter_marker_missing`,
because `filter_markers_unavailable` did not exist until `#313`. The hold keys on the new
reason, which is the only one that distinguishes a configuration fault from an ordinary verdict
— keying on `filter_marker_missing` instead would hold the watermark every time a genuinely
unremarkable artifact failed the allowlist, which is most scans. So the protection applies to
the next equivalent fault, not the recorded one.

## Consequences

**`last_scan.json` freezes during a held outage.** `onlooker doctor` is unaffected: `streams.ts`
deliberately sets `subpath: "lessons"` for librarian precisely because the key-level heartbeat
"masks a stalled stream", so the verdict already ignores this file's freshness. A frozen
watermark alongside flowing events becomes a *positive* fault signature, where today a broken
librarian and a healthy one are indistinguishable.

**A held scan repeats work.** Each session re-reads and re-filters the same window until the
configuration is fixed or the ceiling is reached. The cost is one `load_since` walk plus the
filter; classification does not run, because nothing is kept.

## Testing

| Case | Expectation |
|---|---|
| Fault drops, window under ceiling | watermark unchanged |
| Fault drops, window at/over ceiling | watermark advances, `retry_cap_exceeded` emitted |
| Clean scan with proposals | watermark advances, unchanged from today |
| `detail_too_short` / `filter_drop_pattern` only | watermark advances — honest verdicts never hold |
| Fault drops on the budget-exceeded exit | watermark unchanged |

The fourth case is the one that keeps this from becoming the bug it fixes: a hold triggered by
ordinary verdicts would stall the pipeline permanently on any repo whose artifacts are thin.

## Out of scope, filed separately

**The general invariant.** `librarian_storage_write_last_scan` advancing past artifacts no path
judged is a defect independent of markers. The budget-exceeded exit is the live instance:
`:190` claims "Retained artifacts will be re-scanned on the next session when time permits",
and `:197` advances the watermark three lines later, guaranteeing they are not.

**The schema description repeats the same false claim.** The `budget_exceeded` enum description
reads "Retained artifacts are reconsidered on a later scan, so it is a deferral rather than a
loss." That is not what the code does. The wording should be corrected whether or not the
behavior is.

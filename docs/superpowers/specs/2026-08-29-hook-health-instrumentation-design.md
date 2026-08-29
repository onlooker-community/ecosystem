# Hook-health instrumentation for plugin hooks

**Date:** 2026-08-29
**Tracking:** `ecosystem-449.5` (under epic `ecosystem-449`)
**Status:** designed, not implemented

## Problem

Every wave of the dogfooding rollout states its exit criteria in latency terms — wave 1
"per-edit latency under roughly 1s", wave 2 "`SessionStart` under roughly 5s", wave 3
"per-turn overhead under roughly 1s". No instrument measures any of them.

`hook-health.jsonl` is not a Claude Code feature. It is our own convention: each ecosystem
hook calls `hook_register` from `scripts/lib/validate-path.sh`, which stamps a start time and
installs an `EXIT` trap that writes a record with the elapsed duration. Only ecosystem hooks
call it. A survey of the 50k most recent records shows exactly 14 distinct hook names, all of
them ecosystem's.

Confirmed live in session `3e7d2a32` with wave 1 enabled: lineage and inspector demonstrably
ran, emitting 20 `lineage.change.recorded` and 11 `inspector.run.completed`, and contributed
zero hook-health records. We can prove the plugins ran. We cannot say what they cost.

Wave 0 never surfaced this because ecosystem was the only plugin enabled, so every hook that
fired happened to be one that self-reports. The measurement approach silently assumed that
property survives adding plugins. It does not.

Plugins cannot simply source `validate-path.sh`: each publishes rooted at `plugins/<name>`, so
an installed plugin is its own tree with no ecosystem checkout above it. This is the same root
cause as `ecosystem-ber`, where every plugin's config accessors resolved to nothing and config
fell back to shipped defaults in silence.

## Scope decisions

**Vendor a lib, don't bench externally.** An external harness that feeds synthetic payloads to
each hook would need no plugin changes and add no overhead, but it measures cold hooks in
isolation — not under real session load or lock contention, which is the thing the rollout
exists to feel. Per-hook attribution under real load is what makes a blown budget actionable:
the plan's wave 2 exit says "or the offenders are configured down and re-measured", and you
cannot name an offender from a per-event total.

**Fix the clock in the same change.** The existing instrument calls `python3 -c 'import time'`
twice per hook. Measured on the development machine, that is ~18.7ms per call, so ~37ms of
overhead per instrumented hook. Applied to 31 plugin hooks that is not a rounding error — on
the per-edit path (lineage + inspector) it would add ~74ms to a 180ms baseline, a ~41%
distortion of the very number the wave is gated on.

Clock costs measured on the development machine:

| Source | Cost per call |
|---|---|
| `python3 -c 'import time; ...'` | 18.7 ms |
| `perl -MTime::HiRes` | 6.9 ms |
| `$EPOCHREALTIME` (bash 5+) | 0.08 ms |
| `jq -n now` | free — `jq` is already spawned to write the record |

Note that hooks run under `#!/usr/bin/env bash`, which on macOS resolves to system bash
**3.2.57**, where `$EPOCHREALTIME` does not exist. The cascade must not assume bash 5.

**Re-baseline rather than preserve comparability.** Making the clock cheaper also makes
ecosystem's own hooks faster, so the wave 0 baseline stops being apples-to-apples. Accepted:
accuracy matters more than continuity with numbers that measured a heavier instrument. The
baseline is re-measured as part of this work.

## Design

### `scripts/lib/hook-health.sh`

New canonical lib holding the timing and logging code extracted from `validate-path.sh`: the
`_HOOK_*` state, the clock, the record writer, and the public entry points.

```bash
hook_health_register "<hook-name>"   # stamp start, arm the exit trap
hook_health_success                  # explicit success (optional)
hook_health_failure "<message>"      # explicit failure (optional)
```

Located from its own `${BASH_SOURCE[0]}`, never from a caller-supplied `$PLUGIN_ROOT` and never
through a path that climbs to the repo root — both mistakes end with undefined functions while
the script still exits 0. Fail-soft throughout: if `$ONLOOKER_DIR` is absent or the log is not
writable, the hook proceeds and simply records nothing. A hook must never fail because its
instrument failed.

### Clock cascade

Start time resolves in order: `${EPOCHREALTIME}` if the running shell defines it (bash 5+),
else `perl -MTime::HiRes`, else `python3`, else `date +%s` scaled to milliseconds. The last
rung gives second resolution — durations are coarse but the record still lands, which is
better than dropping it.

End time is taken from `jq -n 'now'` inside the record-writing call that already runs. Both
`now` and the cascade are gettimeofday-based wall clocks, so the two are directly comparable.
Net cost: one extra process per hook, down from two.

### Trap chaining

`hook_health_register` must not clobber an existing `EXIT` trap. Six plugin hooks already
install one for cleanup: assayer, archivist, echo, and tribunal each `rm -f` a prompt file on
exit, and cartographer's two hooks release a lock. A naive `trap ... EXIT` would silently leak
a temp file or, worse, strand a lock — making the instrument the cause of a regression.

`hook_health_register` reads the current handler with `trap -p EXIT`, extracts the command, and
installs a composite that **logs first, then runs the prior handler**. Logging first means the
recorded duration excludes the hook's own cleanup, and guarantees the prior handler still runs
even if logging fails.

### The librarian trap clear: investigated, not fixed

`librarian-classifier.sh` and `librarian-lesson-transform.sh` each set a temp-file `EXIT` trap
around a `claude -p` call and then disarm it with a bare `trap - EXIT`. The original premise
here was that this bare clear would also strip a health trap installed by
`hook_health_register`, silently dropping librarian's `SessionEnd` record. That premise is
false for the code as it exists today, and the fix that premise motivated was not applied.

Both call sites — `librarian-session-end.sh:222` and `:467` — invoke these functions through
command substitution (`RESPONSE=$(librarian_classifier_call ...)`,
`LESSON_RESULT=$(librarian_lesson_transform_one ...)`). Bash forks a subshell for command
substitution, and that subshell inherits the caller's current `EXIT` trap at fork time. The
bare `trap - EXIT` inside the classifier only clears the *subshell's own copy* of that
inherited trap — it never touches the caller's trap table. So under the call shape that
actually exists, the health trap installed by `hook_health_register` survives untouched and
fires exactly once, correctly, when the real top-level hook script exits.

The prescribed fix — capture the prior handler with `trap -p EXIT` and restore it with `eval`
instead of clearing — makes this *worse*, not better. Restoring (re-arming) the trap inside the
subshell means it also fires when that subshell exits, which happens immediately as the
classifier function returns. The result is two records per hook run: one spurious, logged from
inside the command-substitution subshell with a truncated duration, and one real, logged at the
actual script exit. This was caught and independently reproduced outside of bats before landing:
calling `librarian_classifier_call` via `RESPONSE=$(...)` after `hook_health_register` produces
one correct record on the unfixed code and two records (one spurious) with the restore-fix
applied.

The bug the fix targeted — losing the record entirely — is real, but only for a call shape that
doesn't exist anywhere in this codebase: calling `librarian_classifier_call` or
`librarian_lesson_call` *directly*, without wrapping it in `$(...)`, in the same shell as
`hook_health_register`. `test/bats/hook-health.bats` pins the call shape that does exist —
`RESPONSE=$(librarian_classifier_call ...)` after `hook_health_register` must leave exactly one
health record, not zero and not two. If a future refactor changes either call site to invoke
these functions directly instead of through command substitution, the bare clear becomes
unsafe again and that test will start failing, which is the signal to revisit this fix.

### One implementation, two consumers

`validate-path.sh` sources the new lib and keeps `hook_register`, `hook_success`, and
`hook_failure` as thin aliases. No ecosystem hook changes, and there is exactly one
implementation of the timing logic rather than a vendored copy that drifts from the original.

### Vendoring and drift

`scripts/sync-config-loader.sh` generalizes to carry both `config-loader.sh` and
`hook-health.sh` into every plugin's `scripts/lib/`. The self-locating bats suite extends to
assert byte-identity of the vendored `hook-health.sh` across all 16 plugins, the same way it
already catches `config-loader.sh` drift.

### Wiring the hooks

Each of the 31 plugin hook scripts gains two lines near the top — source the vendored lib, call
`hook_health_register` with the hook's name. No hook bodies change.

## Testing

- **Unit.** A register-then-exit cycle writes a record with a plausible duration. The failure
  path records `status=failure` with the exit code. The clock cascade degrades correctly when
  `perl` is unavailable, and when neither `perl` nor `python3` is.
- **Regression, trap chaining.** A hook that installs its own temp-file `EXIT` trap before
  calling `hook_health_register` still deletes the file on exit *and* still produces a record.
  Written against the real assayer/tribunal pattern, since that is the leak this guards.
- **Regression, librarian.** A function that sets and restores its own trap leaves the health
  trap armed, and the record still lands.
- **Vendoring.** Every vendored `hook-health.sh` is byte-identical to the canonical copy, and
  the accessors resolve from a plugin tree copied outside the repo.
- **Integration.** A real plugin hook driven end to end produces a hook-health record naming
  that hook.

No schema work. hook-health is a diagnostic log, not an event-bus emission, so there is nothing
to register in `@onlooker-community/schema` and nothing to triage into `test/bus-coverage.json`.

## Re-baseline

After this lands, re-measure the wave 0 figures under the cheaper clock, with only ecosystem
enabled, and record them alongside the originals — noting that the two are not comparable
because the earlier numbers included ~37ms per hook of measurement overhead. Update the
`dogfood-wave0-baseline` bd memory and the rollout design doc.

## What this deliberately does not do

No change to what a hook records beyond timing — status, duration, session, event, and tool
name are the existing fields and stay as they are. No retention or sharding for
`hook-health.jsonl`, which is already 39MB and shares the unbounded-growth problem filed as
`ecosystem-449.2`; adding writers makes it grow faster, but coupling a storage refactor to this
change would make the re-baseline unattributable.

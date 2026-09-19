# ADR-003: Librarian's LLM Work Runs Detached, Not in SessionEnd

**Status:** Accepted
**Date:** 2026-09-19
**Tracking:** `ecosystem-449.72`

## Context

Librarian classified each surviving candidate inline in its `SessionEnd` hook — one
`claude -p` call per artifact — and ran its lesson transform there too. Both were bounded by a
20-second per-call timeout, and the hook as a whole by the CLI's `SessionEnd` deadline.

**Librarian has never proposed a memory.** `librarian.candidate.proposed` is 0 all-time, and all
3,873 `librarian.candidate.dropped` rows carry a pre-classifier reason. The cause was not the
filter and not the budget guard.

Measured 2026-09-19 against `/opt/homebrew/bin/claude`, which is what a hook actually resolves
(confirmed from non-interactive `bash --noprofile --norc`; the interactive shell's `claude` is a
function that prints "pick an account" and returns 1):

| what | measured |
|---|---|
| trivial prompt (`Reply with exactly: ok`) | 29,910 ms / 28,971 ms |
| classifier prompt (1,224 bytes), answer on stdout | +39,065 ms |
| same call, process exit (`rc=0`) | +46,484 ms |
| shipped per-call timeout | **20 s** |
| `SessionEnd` ceiling (CLI; not raisable from a plugin) | **1,500 ms** |

Two things follow. **The 20-second timeout was below the time a call takes**, so every call was
killed before its answer arrived, returned empty, and was recorded as `classified_null`. And
**~29 of the ~39 seconds is nested CLI session startup**, not model work — this repo loads 16
plugins and several MCP servers into every nested `claude` (`ecosystem-449.73`).

The budget guard was not protecting a working classifier. It was *masking* one that cannot run
here at all: a large window made the durability filter slow enough to trip the guard and exit
before classification, while a small window — the normal case — reached the classifier and hung
until the CLI killed the hook.

Two alternatives were considered and are arithmetically impossible, not merely tight:

- **Cap artifacts classified per session to what the remaining budget allows.** After the filter
  there are a few hundred milliseconds left. One call is ~39 seconds. The cap is zero.
- **Bound each call with a timeout inside the remaining budget.** Any such bound fires on 100%
  of calls. That renames the failure; it does not fix it.

Raising the `SessionEnd` timeout from inside the plugin is not available either: a timeout
declared in a plugin's `hooks.json` does not feed `getSessionEndHookTimeoutMs`, confirmed by the
three-arm probe recorded in PR #338.

## Decision

**No LLM call happens on the `SessionEnd` path.** The hook does the cheap deterministic work —
read the window, run the durability filter — then writes the surviving window to a queue file
and spawns a detached worker, following `plugin-currency-surfacer.sh`'s `_spawn_refresh`: `mkdir`
as an atomic test-and-set, explicit env passthrough, output discarded, `disown`, lock released by
a trap in the child.

`plugins/librarian/scripts/lib/librarian-classify-worker.sh` carries the classifier loop and the
lesson stage, with no ceiling. **The per-call timeout moves to 120 s** and becomes configurable
as `librarian.classifier.timeout_seconds`; `lesson_transform.timeout_seconds` moves with it for
the same reason.

**The worker emits `librarian.scan.complete`, not the hook.** The `outcome` enum is
`ok|empty|skipped|budget_exceeded` with `additionalProperties: false`, and nothing in it means
"queued for a worker".

## Rationale

**The timeout raise and the move are one change.** At 20 s nothing ever returns, so the bound has
to rise. A bound above real latency inside `SessionEnd` would block shutdown for minutes — far
worse than today's failure. Neither half is shippable alone.

**Having the worker emit the completion avoids a schema change and is more truthful.** Inventing
a `deferred` outcome would mean a PR against `@onlooker-community/schema`, a publish and a version
bump, to describe a state no consumer needs. Reporting the real outcome when the work actually
finishes costs nothing and says more. It is also the established shape: the currency probe emits
`onlooker.currency.checked` for itself.

**Advancing the watermark in `SessionEnd` stays safe, so this does not depend on `449.55`.** The
queue file is the durable record — artifacts are handed off, not dropped. The worker removes the
queue only after succeeding, so a worker that dies leaves its input on disk.

That is only true if something later picks it up, and at first nothing did: this hook is the only
writer of queue files, and a later session wrote a *new* one rather than draining the old. A
stranded window would have sat forever behind an already-advanced watermark — the exact loss the
queue exists to prevent, reintroduced one layer down. So `SessionEnd` spawns a worker for every
queued window it finds, not just the one it wrote. Spawning is a fork and a `disown`, and a window
already in flight is a no-op because the worker cannot take its lock; the count is capped, because
if orphans are accumulating then something is wrong and starting an unbounded number of LLM
workers is not how to find out.

## Consequences

- **A session whose worker dies leaves a `scan.started` with no `scan.complete`.** That is
  honest: the scan genuinely did not complete. Since `ecosystem-449.66` that shape is legible
  rather than a silent gap.
- **`duration_ms` on `scan.complete` now measures the whole scan, hook plus worker**, so it jumps
  from sub-1,500 ms to minutes. Per-hook cost is hook-health's job, not this field's. A consumer
  trending this number across the change will see a discontinuity.
- **Proposals appear a session late.** Classification finishes after the session that produced
  the artifacts has ended, so `SessionStart` surfaces them next time. That is inherent to ~39 s
  of work under a 1,500 ms ceiling.
- **A long-lived background process per session with candidates.** Seven artifacts at ~39 s is
  ~5 minutes of detached work. Acceptable because nothing waits on it, and unavoidable until
  `449.73` reduces startup.
- **The queue-write-failure path emits nothing and does not advance the watermark.** `skip_reason`
  has no value describing it, and reaching for the nearest one is the conflation `449.39` records
  against stamping `empty` on two paths that mean opposite things.
- **The worker is not a hook.** It does not register with hook-health and must not call
  `hook_health_exit`. It probes for its own sourced functions instead, because without `errexit` a
  bad `PLUGIN_ROOT` leaves every accessor undefined and still exits 0 — the failure this repo has
  now seen in `ecosystem-ber` and `449.36`.

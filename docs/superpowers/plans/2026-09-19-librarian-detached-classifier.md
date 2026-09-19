# Move librarian's LLM stages out of SessionEnd

**Date:** 2026-09-19
**Tracking:** `ecosystem-449.72` (under epic `ecosystem-449`)
**Status:** in progress

## The measurement this rests on

A hook resolves `/opt/homebrew/bin/claude` (confirmed from non-interactive
`bash --noprofile --norc`). Against that binary, on this machine:

| what | measured |
|---|---|
| trivial prompt (`Reply with exactly: ok`) | 29,910 ms / 28,971 ms |
| classifier prompt (1,224 bytes), answer on stdout | +39,065 ms |
| same call, process exit (`rc=0`) | +46,484 ms |
| shipped classifier timeout | **20 s** |
| shipped `lesson_transform.timeout_seconds` | **20 s** |
| SessionEnd ceiling (CLI, not raisable from a plugin) | **1,500 ms** |

Two conclusions, and the whole plan follows from them:

1. **Both LLM stages time out before the answer arrives.** 20s < ~39s, every
   time. The classifier returns empty, the loop records `classified_null`, and
   every candidate is dropped. This is why `librarian.candidate.proposed` is 0
   all-time (`ecosystem-449.67`) and why all 3,873 `candidate.dropped` rows
   carry a pre-classifier reason. `lesson_transform` shares the defect, which
   is a likely cause of `449.38` and `449.49`.
2. **~29s of the ~39s is nested CLI session startup**, not model work — this
   repo loads 16 plugins and several MCP servers into every nested `claude`.
   Filed as `ecosystem-449.73`. One call is ~26x the entire hook budget, so
   "cap to the remaining budget" and "timeout inside the remaining budget" are
   arithmetically impossible, not merely tight.

## Why the two changes cannot be split

Raising the timeout above real latency is necessary — at 20s nothing ever
returns. But raising it *inside* SessionEnd makes SessionEnd block for up to
120s per artifact, which is far worse than the current failure. So the timeout
raise requires the detached move, and the detached move without the timeout
raise inherits the exact bug it is meant to fix. One change.

## Shape

Follows `scripts/hooks/plugin-currency-surfacer.sh`'s `_spawn_refresh` — the
repo's existing detached-work pattern: `mkdir` as an atomic test-and-set,
explicit env passthrough, `disown`, lock released by a trap in the worker.

```
SessionEnd (stays under 1500ms, no LLM):
  reader -> durability filter -> $KEPT
  KEPT empty  -> emit scan.complete outcome=empty, advance watermark, exit
  otherwise   -> write $KEPT + context to a queue file
                 spawn detached worker
                 advance watermark
                 exit WITHOUT emitting scan.complete

detached worker (no ceiling):
  classifier loop over the queued window
  lessons stage
  emit candidate.proposed / candidate.dropped per artifact
  emit scan.complete with the real counts
  remove the queue file on success only
```

**The worker emits `scan.complete`, not SessionEnd.** That avoids a schema
change: the `outcome` enum is `ok|empty|skipped|budget_exceeded` with
`additionalProperties: false`, and nothing in it means "queued for a worker".
Inventing a value would mean a schema PR, a publish and a version bump. Having
the worker emit the real outcome when it lands is both truthful and free, and
it matches the currency precedent, where the detached probe emits
`onlooker.currency.checked` itself.

The cost is that a session whose worker dies leaves a `scan.started` with no
`scan.complete`. That is honest — the scan genuinely did not complete — and
since `ecosystem-449.66` it is a legible shape rather than a silent gap.

## Watermark

Advancing in SessionEnd is safe here, which is why this does not depend on
`449.55`: the queue file is the durable record, so artifacts are not dropped,
they are handed off. The worker removes the queue only after succeeding, so a
dead worker leaves its input on disk to be retried rather than losing it.

## Tasks

1. `librarian.classifier.timeout_seconds` in config, read by the classifier
   lib instead of the hardcoded constant. Default well above measured latency.
2. `lesson_transform.timeout_seconds` raised for the same reason.
3. Queue writer + `_spawn_classify` in `librarian-session-end.sh`; classifier
   loop and lessons stage removed from the hook.
4. New worker `plugins/librarian/scripts/lib/librarian-classify-worker.sh`
   carrying the moved stages, emitting `scan.complete`.
5. Tests: SessionEnd invokes no `claude` and stays under budget; the worker
   classifies a queued window and emits; a dead worker leaves the queue intact;
   the lock prevents a second concurrent worker.
6. ADR — this changes when librarian's LLM work happens, which is an
   architectural decision, and records why (b) and (c) were impossible.

## Not in scope

- Reducing the ~29s startup (`449.73`). If that lands, this design still holds;
  it just runs faster.
- `449.55`'s watermark hold. Unnecessary for this path, per above.

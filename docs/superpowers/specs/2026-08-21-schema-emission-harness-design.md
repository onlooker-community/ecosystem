# Repo-Wide Schema Emission Harness — Design

**Status:** Approved, not started.
**Tracked by:** `ecosystem-u0t`.
**Single repository.** Everything lands under `scripts/lib/`, `test/`, and
`package.json`.

---

## What this is

Three bugs now share one root cause. A hook built a payload that diverged from
what the published schema admits; the emitter rejected it; the hook swallowed
the rejection and exited 0; the on-disk artifacts kept working. Nothing looked
broken.

- `ecosystem-q4d` (P1, closed) — both cartographer payloads off-contract.
- `ecosystem-1p1` (P2, closed) — librarian `scan.complete` emitted
  `outcome:budget_exceeded`, which the enum rejects.
- `ecosystem-ci0` (P3, open) — cartographer `finding_type:"unknown"`, admitted
  by no schema.

Each fix added its own bats test driving a real payload through
`scripts/lib/onlooker-event.mjs`. That guarantee stops at the plugin being
repaired. Nothing generalizes it, so the next divergence ships the same way:
silently, with green tests and working artifacts. Every instance so far was
found by hand, long after it landed, and each cost a two-repo release cycle.

This builds one harness that makes the class detectable.

## Why the obvious seam is the wrong one

`ecosystem-u0t` proposes enumerating payload builders per plugin, noting that
the `q4d` fix extracted cartographer's builders out of `run_emit` "precisely so
tests and production share one construction — that pattern is the likely seam,
but not every plugin has been refactored that way yet."

The seam does not exist. Counting named `*_payload()` builders across every
`plugins/*/scripts/lib/*-events.sh`:

| Plugin | Builders |
|--------|----------|
| cartographer | 3 |
| every other events lib (12) | 0 |

Three plugins — curator, historian, librarian — have no events lib at all.
Everywhere except cartographer, the payload is assembled inline at the call
site and handed to `<plugin>_emit_event` as a finished JSON string.

Choosing that seam means refactoring fifteen plugins before writing a single
assertion, and the refactor would be driven by a test rather than by need.
Rejected.

## The failure signature

The rejection is not a bad line on the bus. It is the **absence** of a line.

Probing the emitter directly with a payload that violates
`governor.gate.checked`:

```
EMITTER EXIT=1
stderr: [ { "path": "/decision",
            "message": "must be equal to one of the allowed values" }, ... ]
bus:    NO LOG FILE — event was dropped
```

Per [ADR-005](../../adr/005-runtime-emitter-fails-open.md), validation is
attempted through a lazy `await import('@onlooker-community/schema')`. Where
the package resolves — dev, CI, tests — the emitter validates and **rejects**.
Where it does not, it emits anyway. So in CI an invalid payload never reaches
the log, and sweeping the log for invalid lines would find nothing, ever.

Hooks fail soft and exit 0 by design, which discards the emitter's exit 1 and
its stderr. That is the whole bug: the only two signals the emitter produces
are both destroyed before anyone can see them. `ecosystem-1p1` established the
usable property in the other direction — presence on the bus proves the payload
validated.

The harness therefore has to capture the rejection at the point it happens, in
a place that outlives the hook.

## Architecture

```
107 bats files -> real hooks -> real branches
                                     |
                      scripts/lib/onlooker-event.mjs
                                     |
                            tryValidate(event)
                     +---------------+---------------+
                  valid                          rejected
                     |                               |
               bus (per-test,                  dropped, exit 1,
                ephemeral)                    stderr swallowed
                     +---------------+---------------+
                                     |
             $ONLOOKER_TEST_REPORT_DIR/emissions.jsonl   <- durable
                  { event_type, validated, valid, errors? }
                                     |
                      Gate A                    Gate B
                 no valid:false line     manifest accounts for 125
```

## Why a durable report directory

`test/helpers/setup.bash:15` points `ONLOOKER_DIR` at
`${BATS_TEST_TMPDIR}/home/.onlooker`. Bats deletes that tree after **each
test**, so a sidecar written under `$ONLOOKER_DIR` dies with the test that
produced it and neither gate could read it afterward.

A shared bats `teardown` was considered and rejected. Teardown is per-file: a
definition in the shared helper would clobber the one bats file that already
defines its own, and any future file defining a teardown would silently opt out
of the gate — the same silent-opt-out failure mode that produced `u0t`.

Instead the suite exports `ONLOOKER_TEST_REPORT_DIR` once, outside
`BATS_TEST_TMPDIR`. One mechanism then feeds both gates, with no per-test
opt-in to forget.

## The emitter change

In `scripts/lib/onlooker-event.mjs`, after `tryValidate`: when
`ONLOOKER_TEST_REPORT_DIR` is set, append one JSON line recording the event
type, whether validation actually ran, whether it passed, and any ajv errors.

Constraints:

- Guarded entirely on the environment variable. Production never sets it, so
  production behavior, exit codes, and the fail-open contract are untouched.
- One `appendFileSync` of one line, so the record is atomic under POSIX
  `O_APPEND` for the line sizes involved.
- Records **`validated`** separately from **`valid`**. This is not redundant;
  see below.

Roughly twelve lines. It is the only production file this design touches.

## Gate A — no rejected emission

Fails if any line in `emissions.jsonl` has `valid:false`, reporting the event
type and the ajv errors that caused it.

It additionally asserts that **at least one line recorded `validated:true`**.
Without that assertion the gate is a trap. If `node_modules` is ever absent,
`tryValidate` fails open, nothing validates, no line is ever `valid:false`, and
Gate A passes green while checking nothing at all — reproducing the exact bug it
exists to catch, one level up. Recording whether validation ran is what makes
that state detectable rather than indistinguishable from success.

## Gate B — every registered type accounted for

A committed manifest, `test/bus-coverage.json`:

```json
{
  "expected": ["session.start", "governor.gate.checked", "..."],
  "excluded": {
    "meridian.hint.generated": "meridian plugin lives in another repo",
    "curator.finding.contradiction": "LLM contradiction sweep deferred",
    "compass.check.overridden": "compass has no implementation yet"
  }
}
```

Gate B asserts three things:

1. Every type in `expected` appears in `emissions.jsonl` with `valid:true`.
2. `expected` and `excluded` together equal `ALL_EVENT_TYPES` exactly — no
   gaps, no extras.
3. Every exclusion carries a non-empty reason.

Assertion 2 is the anti-drift property. A newly registered schema type belongs
to neither list, so CI fails until someone triages it deliberately. This is the
same shape as the `test:shellcheck` fix in #190: derive coverage from the
authoritative set rather than from a hand-maintained list that rots.

All three assertions are hard from the first commit: the manifest is authored
during implementation precisely to make them true. What ratchets is the
manifest itself, as types move from `excluded` to `expected` when the features
that emit them land.

## Where the gates run

The gates become their own npm script, `test:bus`, sequenced after `test:bats`
in `test:ci`. It **fails when the report is missing**.

They deliberately do not live inside `test:schema`. A node test that skips when
the report is absent would pass vacuously for anyone running `test:schema`
standalone — silent skipping being, again, the failure mode under repair.

`test:bats` clears and exports the report directory; the path is gitignored.

## Bootstrapping the manifest

Of 125 registered types, 75 are referenced in this repo's source and 50 are
not. The 50 split three ways, and each group takes a different disposition:

| Group | Count | Disposition |
|-------|-------|-------------|
| Foreign plugins — meridian 6, sentinel 3, oracle 2, relay 2 | 13 | `excluded`, "plugin lives in another repo" |
| In-repo but unemitted — curator 11, tribunal 6, archivist 5, governor 4, historian 3, librarian 2, compass 2, and three singles | 36 | `excluded`, with the specific reason |
| `onlooker.session.summary` | 1 | `excluded`, emitted by the agent, not this repo |

Curator's eleven are deferred by design; compass has no implementation at all
and is still in its design phase. Those move to `expected` as the features land,
which is the ratchet working as intended.

Note that source reference is not emission. The initial `expected` list is
seeded from what the first instrumented run actually observes, not from the 75
grep hits — a type named only in a comment or a doc would otherwise be demanded
to have an example it can never produce.

## Testing the harness itself

Three checks, each broken on purpose before being trusted:

1. Feed a known-bad payload through the emitter with the report directory set;
   confirm a `valid:false` line appears and Gate A goes red.
2. Remove a type from `expected` that the suite does emit; confirm assertion 2
   fails on the resulting gap.
3. Simulate the schema package being unresolvable; confirm Gate A fails on the
   absence of any `validated:true` line rather than passing green.

Check 3 is the one that matters most, because it is the only one that tests the
harness against its own failure mode.

## Out of scope

- **Refactoring fifteen plugins to extract payload builders.** The integration
  seam makes it unnecessary.
- **Forcing coverage of the 36 unemitted in-repo types now.** They are
  excluded with reasons and promoted as features land.
- **Parallel bats.** The suite runs serially. Running `bats -j` would need
  append-atomicity revisited; not addressed here.
- **The `-S error` shellcheck severity question.** Unrelated, separately filed.

## Acceptance

- `npm run test:ci` runs `test:bus` after `test:bats` and fails when the report
  is missing.
- Gate A fails on a rejected emission, naming the type and the ajv errors.
- Gate A fails when validation never ran, rather than passing vacuously.
- Gate B fails when a registered type appears in neither manifest list.
- `ecosystem-ci0`'s `finding_type:"unknown"` payload is caught by Gate A once
  a test exercises that branch, without a bespoke test being written for it.
- Production emission behavior is unchanged: no new dependency, no exit-code
  change, and nothing written unless `ONLOOKER_TEST_REPORT_DIR` is set.

## Documentation to update

- `docs/architecture.md` — how the bus gates fit the event pipeline.
- `CLAUDE.md` — the "Adding a new plugin" checklist gains a step: triage any
  new event type into `test/bus-coverage.json`.
- `.claude/skills/writing-tests/SKILL.md` — note that emissions are gated
  suite-wide, so new plugins need no bespoke schema test.

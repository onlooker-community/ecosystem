# Plugin currency surfacer

Design for `ecosystem-449.59` — surfacing stale plugin pins at SessionStart.

## Problem

Plugin pins go stale on every release and nothing tells you.

`ecosystem-o2s` established the mechanism. A `/plugin` update writes user scope
plus *the current project's* scope and nothing else, and it is per-plugin rather
than a blanket refresh. Nothing fetches a marketplace clone on a schedule. So
after every release, every checkout keeps loading the prior version until a human
runs `/plugin` from inside that checkout, for each plugin.

The condition is live as of writing. PR #317 released ecosystem 0.55.0 at
2026-09-12T01:22:24Z. The marketplace clone sits at `6caacd3` (#315); live
`ls-remote` returns `ff773b41`; the last fetch *attempt* was 2026-09-11T23:41:43Z,
an hour and forty minutes before the release. The running set is 0.54.4.

Detection is already solved. `scripts/lint/check-plugin-installs.mjs` (PR #316)
names the condition accurately:

```text
error: marketplace onlooker-community clone is behind its origin
(6caacd39 < ff773b41); last fetch attempt 2026-09-11T23:41:43Z
```

What is missing is that **nobody runs it**. `lint:plugin-installs` belongs to no
CI job and to no npm aggregate. The detection fires only when someone thinks to
ask, and the people whose pins are stale are precisely the people not asking.

## Goals

1. Warn at SessionStart, unasked, when the plugin code this session is about to
   run is not the code on main.
2. Record a decision about whether `lint:plugin-installs` joins `test:ci`.
3. Bound the cost so an always-on substrate hook stays cheap and works offline.

## Non-goals

- **Fixing the drift.** There is no non-interactive install path; the remedy is
  the in-session `/plugin` command. See the `dogfood-enabling-is-not-installing`
  memory. This feature reports and stops.
- **Warning about the current staleness.** See the bootstrap limit below.
- **Deciding staleness policy for unrelated marketplaces.** `mise`,
  `dotfiles`, `git-workflow`, `superpowers-dev` and `conorbronsdon-skills` are
  all behind right now. That is a fact about the machine, not about this repo,
  and this surface scopes them out rather than ruling on them.

## Decision: `lint:plugin-installs` does not join `test:ci`

Recorded here because `ecosystem-449.59` acceptance 1 asks for it.

Three local-state lints sit outside `test:ci` today: `lint:plugin-installs`,
`lint:plugin-liveness`, and `lint:lib-skew`. All three read machine state —
`installed_plugins.json`, marketplace clones, the runtime JSONL logs — and all
three exit 0 when no manifest is present. Verified:

```text
check-plugin-installs -> exit 0
check-plugin-liveness -> exit 0
check-shared-lib-skew -> exit 0
```

CI therefore *provably cannot* observe what they check: it runs against a clean
checkout with no `~/.claude*` and always runs `npm ci`. Adding them to `test:ci`
would be a guaranteed no-op in CI, and would only ever fire for a developer
running the full suite locally.

For that developer it would be actively harmful today. Unscoped, the check exits
non-zero because of five findings in marketplaces unrelated to this repo. A
suite that fails for reasons the developer cannot act on and did not cause is a
suite people learn to ignore, which costs more than the check gains.

So: not `test:ci`. SessionStart is the right surface, because the condition that
matters — "the code this session is about to run is not the code on main" — is
true at session start and knowable from data already on disk.

## Architecture

Reuse rather than reimplementation. `check-plugin-installs.mjs` is 489 lines and
already does the whole job, and `scripts/lint/` ships inside the installed
plugin. The hook is a thin bash wrapper, which is what the repo conventions
prescribe: hooks are bash, and may shell out to `node` for heavy lifting.

```text
SessionStart (matcher: *)
└─ scripts/hooks/plugin-currency-surfacer.sh
   ├─ read  $ONLOOKER_DIR/currency/<project-key>/probe.json
   ├─ fresh (age < probe_ttl_hours) → surface from cache, no network
   └─ stale or absent              → node scripts/lint/check-plugin-installs.mjs \
   │                                    --json --marketplace onlooker-community
   │                                 → write probe.json {checked_at, findings[]}
   ├─ emit onlooker.currency.*
   └─ inject one-line additionalContext, or nothing
```

### Why the substrate and not a plugin

Per-plugin enablement shapes what gets noticed, and this epic produced two
demonstrations. `ecosystem-449.28`: the dogfooding soak ran in the `onlooker`
repo rather than here, so the staged waves went unobserved. `ecosystem-449.34`:
an outage was diagnosed as "librarian" because librarian was the plugin enabled
in the arena where someone happened to look, when curator and historian carried
the identical defect.

A currency warning that fires only for people who enabled it will systematically
miss the people whose pins are stale, because those are the same people. The
substrate is the one component that cannot be the thing you forgot to enable.

### Naming

`plugin-currency-surfacer.sh`, not `-tracker.sh`. Most substrate hooks are
`*-tracker` because they log; this one injects. `prompt-rule-injector.sh` is the
existing precedent for a substrate hook named for a non-tracking job.

## The scope filter

`check-plugin-installs.mjs` gains a repeatable `--marketplace <name>` flag.

Implementation is contained: `report.findings` is already a flat array whose
entries carry either a `plugin` key (`mise@meaganewaller-marketplace`) or a
`marketplace` key (`superpowers-dev`). The filter drops non-matching findings
before `report.status` is computed and before the error-printing loop, so exit
code and output stay consistent with each other.

Default behavior is unchanged: with no `--marketplace`, every marketplace is
reported, so `npm run lint:plugin-installs` still shows the whole machine. Only
the hook passes a filter, from `plugin_currency.marketplaces` in config.

This is what lets the surface be quiet about `mise` and `dotfiles` without this
repo having to rule that their staleness is noise in general.

## Cache design and the age rule

`$ONLOOKER_DIR/currency/<project-key>/probe.json`:

```json
{
  "checked_at": "2026-09-12T04:11:07Z",
  "findings": [
    {
      "reason": "clone_behind",
      "marketplace": "onlooker-community",
      "head": "6caacd39",
      "remoteHead": "ff773b41"
    }
  ]
}
```

**The governing invariant: absence of a finding in an expired cache is not
evidence of currency.**

This is the single constraint most likely to be violated by a later change, and
violating it reproduces the exact outage the feature exists to catch. A detector
that reports a cached "you're current" as though it were fresh is doing what
`refs/remotes/origin/main` does — answering from a stale cache with no signal
that it is stale. Two instruments have already caused wrong conclusions in this
epic this way: `refs/remotes/origin/<branch>` reported a behind clone as current
(`ecosystem-o2s` acceptance 1–3), and `lastUpdated` read without `installedAt`
made never-updated worktree pins look freshly updated (`ecosystem-o2s`
acceptance 6).

Concretely:

- The surfaced line always states the answer's age, never a bare verdict.
- Past TTL with no successful re-probe, the hook says "unchecked for Nh" or stays
  silent. It never says "current".
- A failed probe — offline, timeout, budget exceeded — leaves the previous
  `checked_at` untouched rather than stamping a fresh time on an old answer.

### Cost, and why the probe is detached

**Amended after implementation.** This section originally specified a bounded
*synchronous* probe. Measurement killed that: the live probe costs **4646ms**
against this repo, versus 157ms for `--offline`. Blocking SessionStart on ~5s is
the defect `ecosystem-449.43` already tracks against scribe-stop, so raising the
budget would have traded a silent failure for a latency regression this repo
treats as a bug.

The probe therefore runs **detached**. The hook reads the cache synchronously
and returns — measured 417ms end to end — and spawns a background probe whose
answer lands for the *next* session. `mkdir` on a lock directory is the atomic
test-and-set that stops two sessions piling up probes.

The age rule is exactly what makes this safe. A session whose answer has expired
does not get a fresh one, and says so: "unchecked", never "current". Being one
session behind is acceptable precisely because the hook never overstates what it
knows.

Cache writes are write-then-rename, because a detached probe can be writing
while another session reads.

Offline is a normal case, not an error: `ls-remote` fails, the probe fails, the
cache is untouched, and the age rule causes the hook to say "unchecked" rather
than to guess.

### The finding shape is not the schema shape

Also learned at implementation time, and load-bearing. `check-plugin-installs`
emits findings as `{plugin, marketplace, head, remoteHead, lastFetchAttempt}`;
the schema requires `{reason, subject, effective, available}` with
`additionalProperties: false`. Passing the raw shape through produced `stale`
events that failed validation and said so to nobody, because the runtime emitter
fails open unless `ONLOOKER_VALIDATE=1` ([ADR-005](../../adr/005-runtime-emitter-fails-open.md)).

The probe maps between them. Tests use samples copied from a real run rather
than fixtures authored against the schema — the latter only prove the hook
agrees with its author's beliefs about the program it calls.

### Surfacing, and repeat surfacing

The injected line is one line, clipped to `max_pointer_chars`. It names the
condition, the age of the answer, and the remedy. Shape:

```text
ecosystem 0.54.4 running, marketplace has 0.55.0 (checked 2h ago) — /plugin to update
```

A finding that persists surfaces on **every** session start until it is
resolved, and this is deliberate. The alternative — surface once, then suppress
— reintroduces the failure mode being fixed: the original outage ran for 21
hours across at least two sessions precisely because nothing re-raised it. A
condition that is still true is still worth saying.

The cost of that choice is nagging, and the bound on it is `surface_when_current:
false`. The hook is silent whenever there is nothing wrong, so a developer whose
pins are current never sees the line at all, and a developer who sees it every
session has a real unresolved problem and one command to fix it.

## Config

New `plugin_currency` key in the root `config.json`, beside `prompt_rules`. User
overrides follow ADR-004.

```json
"plugin_currency": {
  "enabled": true,
  "marketplaces": ["onlooker-community"],
  "probe_ttl_hours": 6,
  "wall_clock_budget_ms": 1500,
  "surface_when_current": false,
  "max_pointer_chars": 200
}
```

`surface_when_current` defaults to `false`: a session start that has nothing to
report should print nothing, matching curator's `surfacer.skip_when_zero`.

## Events

Three new types, registered in `@onlooker-community/schema` before any emission:

| Type | When |
| --- | --- |
| `onlooker.currency.checked` | a probe ran, with its outcome |
| `onlooker.currency.stale` | one or more findings survived the scope filter |
| `onlooker.currency.skipped` | cache fresh, disabled, no manifest, or budget exceeded |

`onlooker.currency.skipped` carries a reason, because "nothing to report" and
"could not check" are opposite conditions that look identical in the log
otherwise — the mistake `ecosystem-449.39` records against
`librarian.scan.complete`.

All three need triage into `test/bus-coverage.json`, `expected` where a test
drives the branch.

**A gap the detached design opened:** `skip_reason` has no value for "the answer
expired and a refresh is in flight". That is not `probe_failed` — the probe has
not failed, it has not finished — and stamping it would conflate two conditions,
which is the mistake this enum exists to avoid. The defer path emits nothing
rather than something false, which is honest but lossy: the feature's most
common transition leaves no event. Tracked as `ecosystem-449.60`.

### Cross-repo sequencing

`@onlooker-community/schema` is a separate repository. `test:bats` and
`test:schema` both set `ONLOOKER_VALIDATE=1`, so an unregistered type fails the
suite here. The schema change lands first.

State of that repo as measured:

- `origin/main` is at `5751691`, release 2.19.0 (#63), confirmed by live
  `ls-remote`, last fetched 2026-09-11T20:29:42Z.
- npm `latest` is 2.19.0.
- This repo's lockfile pins 2.18.1 and declares `^2.18.1`.
- The local checkout is on `feat/watch-unmatched`, one unpushed commit on top of
  2.17.0 — two releases behind main.

The schema branch is therefore cut fresh from an updated `main`, not from the
local WIP branch. Order: schema PR → publish → bump the devDependency here →
build the hook.

## Bootstrap limit

The feature cannot warn about the staleness present when it ships.

Measured: the installed `ecosystem/0.54.4` copy carries the 198-line
presence-only `check-plugin-installs.mjs` from #250. The 489-line currency
version is in `main` and ships first in 0.55.0. A hook shipped in 0.55.0 does not
exist in a session running 0.54.4.

This is inherent to any self-checking mechanism and is not a defect, but it must
be stated rather than implied: the first session this helps is the one *after*
the next successful update.

## Testing

- **bats**, `test/bats/plugin-currency-surfacer.bats` — fresh cache is read
  without a probe; expired cache triggers a probe; failed probe leaves
  `checked_at` untouched; expired cache with no re-probe never emits "current";
  `enabled: false` is a clean no-op; missing manifest is a clean no-op; the hook
  always exits 0.
- **node**, extending `test/node/check-plugin-installs.test.mjs` — a single
  `--marketplace` filters other marketplaces out of findings and out of the exit
  code; repeating the flag unions the set; an unknown name yields no findings
  rather than an error; omitting it preserves today's behavior exactly.
- **bus coverage** — all three new types triaged.
- The hook calls `hook_health_register "plugin-currency-surfacer"` before any
  work and `hook_health_context "$INPUT"` after reading stdin, per repo
  convention and enforced by `test/bats/hook-health.bats`.

The age-rule tests are the load-bearing ones. "Expired cache never reports
current" should be written so that removing the age check fails it.

## Acceptance

Mapping to `ecosystem-449.59`:

1. Decision recorded on `test:ci`, with the other-marketplace noise scoped out
   via `--marketplace` rather than accepted or suppressed globally. — this doc.
2. SessionStart surfaces the current condition unasked, subject to the bootstrap
   limit above.
3. Fresh-worktree snapshot behavior — a new worktree freezes at whatever the
   clone held at creation time, as `ecosystem-449.48` (0.54.1) and
   `ecosystem-449.55` (0.54.2) both did — is **out of scope here**. This surface
   makes it visible, which is the prerequisite for fixing it. Tracked separately.

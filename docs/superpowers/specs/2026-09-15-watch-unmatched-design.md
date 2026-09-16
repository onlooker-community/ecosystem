# Watch-unmatched signal

Design for `ecosystem-449.21` — telling a correctly idle plugin apart from a dead one.

## Problem

A plugin that exits 0 and emits nothing looks exactly like a plugin with nothing
to report. The bead calls this the fifth instance of one family in a single
dogfooding pass (`ecosystem-449.10`, `.12`, `.13`, `.15`, `449.18`/`68z`), and the
family keeps recurring because the ambiguity is invisible from the consuming side:
absence is the only signal, and absence has two causes.

Measured against `hook-health.jsonl` and the event bus on 2026-09-15:

| plugin | fires since its last emitted event | last event |
|---|---|---|
| tribunal | 543 | 2026-09-05T21:38:09Z |
| cartographer | 515 | 2026-09-07T23:07:24Z |
| echo | 424 | 2026-09-07T17:49:38Z |
| scribe | 166 | 2026-09-13T05:27:54Z |

Not one of those is provably broken. That is the whole problem. Each may be
correctly idle, and from the bus there is no way to find out — which makes every
downstream finding in epic `ecosystem-449` rest on a signal that cannot
distinguish working from dead.

Two of those four are in scope here, because they are the two whose idleness is
governed by a *pattern list that might match nothing at all*:

- **echo** — `echo-stop-gate.sh:161` does `[[ ${#WATCHED_CHANGED[@]} -eq 0 ]]` and
  skips. Correct for the common case, since most turns change no agent files. It
  is indistinguishable from `watch_paths` matching nothing in the repository
  *ever*. The hook already carries a comment at line 162 naming this bead.
- **cartographer** — `undocumented_entity.globs` are walked only inside the
  24-hour audit, so a glob list that matches nothing produces the same silence as
  a throttled audit.

The distinction worth reporting is not "no changed file matched this turn" —
constant and noisy — but "these patterns match zero paths in this repository," a
property of repo plus config rather than of the turn.

### What unblocked this

The bead was filed 2026-09-03 and marked BLOCKED on a schema release, because
`@onlooker-community/schema` is an external dependency and a new event type
cannot be registered from this repo.

That blocker is gone, and it has been gone longer than the bead knows. The
timeline is worth stating precisely, because "the type exists" and "the type is
usable" were two different dates:

- **2.18.0** — `onlooker.watch.unmatched` is *defined*. The `test/bus-coverage.json`
  exclusion entry records this, along with the instruction to move it to
  `expected` when a plugin starts emitting it.
- **2.20.0** — `ONLOOKER_WATCH_UNMATCHED` is *re-exported from `index.ts`*. Until
  then it was defined but unreachable by consumers, which is why the bead stayed
  blocked through two releases that nominally contained it.
- **2.21.0** — the installed and declared version (`package.json` has `^2.21.0`).
  Verified reachable: one export in `dist/index.js`, and the payload in
  `schemas/payload/plugins-ops.json`.

No schema PR is needed. The bead's own open design question — a per-plugin
`echo.watch.unmatched` versus a substrate-level signal covering the class — was
answered by what shipped: the registered type is `onlooker.watch.unmatched`, the
generalized form, carrying the plugin as a payload field.

## Goals

1. Emit `onlooker.watch.unmatched` when a plugin's configured patterns match zero
   paths in the repository.
2. Emit it rarely enough to be a signal — once per (project, pattern set) — and
   often enough to stay visible in a recent bus window.
3. Make the check agree with each plugin's real matcher, so it never invents a
   misconfiguration that is not there.

## Non-goals

- Reporting "no changed file matched this turn." That is `echo.suite.skipped`,
  which already exists (`ecosystem-449.52`, PR #329). Overloading it would corrupt
  the one stream a consumer would use to ask whether a plugin is doing anything.
- Covering tribunal or scribe. Their silence has different causes and the shipped
  `plugin` enum admits only `echo` and `cartographer`.
- Making the TTL configurable. Nothing has asked for it to vary.

## The schema constrains the payload

```json
{
  "required": ["plugin", "config_key", "patterns"],
  "additionalProperties": false,
  "properties": {
    "plugin": { "enum": ["echo", "cartographer"] },
    "config_key": { "type": "string" },
    "patterns": { "type": "array", "items": { "type": "string" } },
    "candidates_scanned": { "type": "integer", "minimum": 0 },
    "project_key": { "type": "string" }
  }
}
```

`additionalProperties: false` means the five fields above are the whole vocabulary.
There is no mode field and no timestamp field — the envelope carries the latter.
Adding a third plugin requires widening the enum, which requires a schema release.

**`candidates_scanned` is omitted in `dirs` mode.** It is optional, and in that
mode it would be a constant 0: under `nullglob` an unmatched glob produces zero
loop iterations, so the counter reads 0 in precisely the case that emits. A field
that looks like a measurement and never varies is worse than an absent one — the
same reasoning that made compass's `confidence` null rather than 0 in
`ecosystem-449.45`. In `files` mode it counts the real candidate set — tracked
plus untracked-but-not-ignored — and is sent.

## Shared helper

New canonical `scripts/lib/watch-unmatched.sh`, added to **`ON_DEMAND_LIBS`** in
`scripts/sync-shared-libs.sh` — not `SHARED_LIBS`.

The sync script draws that line itself: `SHARED_LIBS` "land in every plugin,
because every hook uses them"; `ON_DEMAND_LIBS` "land only where a copy already
exists, because a copy nobody sources is noise that still has to be kept in
sync." Only echo and cartographer source this lib, so `SHARED_LIBS` would mint
fourteen copies nothing reads. `portable-lock.sh` sits in 5 of 16 plugins on
exactly this basis.

The cost is that adoption is manual: on-demand libs are never created by the
sync, only refreshed where already vendored, so the first copy into each of the
two plugins is a deliberate `cp`. Drift afterward is caught by
`shared-lib-vendoring.bats`'s `the sync script reports no drift` case, which runs
`sync-shared-libs.sh --check`. That file's per-plugin assertions enumerate
`SHARED_LIBS` only, and correctly do not apply here.

The lib resolves its own siblings from `${BASH_SOURCE[0]}` — never from a
caller-supplied `$PLUGIN_ROOT`, never through a path that climbs to the repo root
(CLAUDE.md item 8). It returns 0 on every path, including every failure
(CLAUDE.md item 7).

```bash
onlooker_watch_unmatched_check \
    --plugin       echo \
    --config-key   echo.watch_paths \
    --root         "$WORKTREE_ROOT" \
    --project-key  "$PROJECT_KEY" \
    --mode         files \
    --patterns-json "$WATCH_PATTERNS_JSON" \
    --emit-fn      echo_emit_event
```

`--emit-fn` keeps the helper emission-agnostic. `echo_emit_event`
(`echo-events.sh:57`) and `cartographer_emit_event` (`cartographer-events.sh:152`)
take identical arguments — `(event_type, payload_json)` — so the helper invokes
the caller's own emitter and each plugin's envelope handling keeps working where
it already works. The helper never writes to the event log directly.

Private internals: `_scan_candidates`, `_marker_due`, `_marker_write`,
`_marker_clear`.

`--patterns-json` takes a JSON array, because that is the shape the payload
requires and the shape `cartographer_config_undocumented_globs` already returns
(`cartographer-config.sh:110`). Echo's `echo_config_watch_paths` returns
newline-delimited patterns, so the echo call site converts before calling. The
helper does not accept both shapes; one input format, converted at the one call
site that needs it.

## Two scanners, not one

The modes are not cosmetic. Each mirrors the matching rule its plugin actually
uses at runtime, because a check that disagrees with the real matcher produces
false alarms, which is worse than the silence it replaces.

| mode | mechanism | mirrors | `candidates_scanned` |
|---|---|---|---|
| `files` | `git -C "$root" ls-files` + `git -C "$root" ls-files --others --exclude-standard`, then `[[ "$f" == $pat ]]` | `echo-stop-gate.sh:135` (`ALL_CHANGED`'s candidate set) | tracked + untracked-but-not-ignored files listed |
| `dirs` | `for match in "${root}"/$glob` under `nullglob`, then `[[ -e "$match" ]]` | `cartographer-omission.sh:77` | paths examined |

Cartographer expands its globs against the **filesystem**, not against git, so it
matches untracked and gitignored paths. Echo's own candidate set (`ALL_CHANGED`,
`echo-stop-gate.sh:135`) is git-tracked paths plus untracked-but-not-ignored
paths — it also walks `git ls-files --others --exclude-standard` — so the files
scanner mirrors that same union, not `git ls-files` alone. This is the single
most important detail in the design: the two scanners exist because the two
matchers differ, not because the code was not factored. The two candidate sets
are coupled: changing `ALL_CHANGED`'s composition in `echo-stop-gate.sh`
requires changing this scanner to match.

`dirs` mode must save and restore `nullglob`, as `cartographer-omission.sh:67`
does — the lib is sourced, not run.

The remaining boundary between the two scanners is gitignored paths: `files`
mode excludes them (`--exclude-standard` omits anything `.gitignore` covers,
matching echo's real matcher), while `dirs` mode still sees them, because shell
glob expansion against the filesystem has no concept of `.gitignore`. That is
where the files/dirs contrast now lives — not untracked-versus-tracked, which
the two modes now agree on.

Consequence to state plainly: in `files` mode, a pattern matching only a
gitignored path reports unmatched. That is correct for this purpose: echo never
scores that file either, because `ALL_CHANGED` excludes it the same way.
Echo's baselines are keyed on `echo_content_sha256` of the working-tree file
(`echo-stop-gate.sh:231`), not on committed content, which is consistent with
scanning the working tree here rather than a git object.

## Marker and re-emission

```
$ONLOOKER_DIR/watch-unmatched/<project-key>/<config-key>.json
{ "patterns_hash": "…", "last_emitted": "2026-09-15T…Z" }
```

Emit when the marker is absent, when `patterns_hash` differs, or when
`last_emitted` is older than the TTL. Delete the marker whenever the patterns do
match, so a repository that is fixed and later re-broken emits again.

- **Hash over the sorted pattern list.** Reordering `watch_paths` is not a
  change in meaning and must not re-arm the signal; editing one is and must.
- **TTL of 168 hours**, a documented constant in the helper. Pure edge-triggering
  was considered and rejected: an event emitted once on 09-07 is invisible to a
  query over the last two days, which is the exact ambiguity this bead exists to
  remove. The TTL keeps a live misconfiguration inside any recent window.
- **Write-then-rename**, following `plugin-currency-cache.sh`. Concurrent sessions
  in one project will race on this file.
- `$ONLOOKER_DIR` always, never a hardcoded `~/.onlooker` (CLAUDE.md item 3), so
  the suite's temp home is respected.

Steady-state cost is one `stat`. The scan runs only when the marker says the
check is due: ~653 tracked files plus the untracked-but-not-ignored ones, two
`git ls-files` invocations at ~6ms each in this repository, so a
due check costs well under 50ms.

Because the scan is gated behind the marker, clearing lags by up to one TTL. A
repository whose patterns start matching again keeps its marker until the next due
check observes the match and deletes it. This is deliberate and harmless — the
marker only ever suppresses emission, and a matching repository has nothing to
emit. The alternative, scanning on every fire to keep the marker exact, pays the
scan cost forever to keep a file tidy that no consumer reads.

## Call sites

**`echo-stop-gate.sh`** — after `echo_config_load` and `PROJECT_KEY`, and
**before** the `ALL_CHANGED` gate at line 117. Placement is deliberate. A watcher
that can never match is most likely to be invisible in exactly the quiet repos
where nothing changed this turn, and line 117 returns before the patterns are even
loaded. This requires hoisting the pattern load from line 123 above that gate, and
retires the TODO comment at line 162.

It also sits above the `command -v claude` guard at line 87. That guard returns
before line 117, so a check placed only below it would never run in a repository
without `claude` on `PATH` — including the whole bats suite. The check needs git
and jq, not `claude`, and someone whose tooling is incomplete still deserves to
learn their config is dead.

Root is `WORKTREE_ROOT`, not `REPO_ROOT` — the tree the session is actually in,
per `ecosystem-449.37`. Echo already draws this distinction at line 79 for its
changed-file scan.

**`cartographer-session-start.sh`** — before the audit-interval gate, so the check
reports even when the audit is throttled, lock-contended, or timing out. Those are
the conditions under which a dead config is most likely to go unnoticed: the audit
has completed zero times since 2026-09-07.

Root is `REPO_ROOT` from `cartographer_project_repo_root`, which is what the hook
already computes and what `run-audit.sh` passes down to the matcher. Note this is
*not* the same choice echo makes, and the difference is not an inconsistency to
tidy up: the governing rule is that each check mirrors its own plugin's matcher,
and cartographer has no worktree-root helper because its matcher never used one.
Changing cartographer's root belongs to `ecosystem-449.37`, not here.

## Testing

New `test/bats/watch-unmatched.bats` drives the public function directly across
both modes: patterns that match, patterns that match nothing, a marker that
suppresses a second emit, a changed hash that re-arms, an expired TTL that
re-arms, and a match that clears an existing marker. Call-site coverage goes in
the existing echo and cartographer hook suites.

Everything routes through `test/helpers/setup.bash` for the isolated temp home and
the project-key helper, per the `writing-tests` skill — no hand-rolled setup, no
real `~/.onlooker/`, no wall-clock dates that become time bombs.

Two specific hazards:

- **Mutation-test every assertion that watches for an absence.** A test asserting
  "no second event was emitted" passes when the emitter is broken outright. Break
  the suppression deliberately and confirm the test fails, or it is decoration.
  This is how the spawn-detection stub in `plugin-currency-surfacer.bats` nearly
  went vacuous.
- **The suite runs parallel (`-j 4`).** Tests must not assume the marker directory
  starts empty beyond their own temp home.

`onlooker.watch.unmatched` is already triaged in `test/bus-coverage.json`, under
`excluded`, with the reason "no plugin emits it yet … move to expected with that
change, not before." This work is that change, so the entry **moves** from
`excluded` to `expected` rather than being added (CLAUDE.md item 6). `npm run
test:bus` passes on the branch today at 622 emissions and must still pass after.

## Risks

- **A third plugin needs a schema release.** The `plugin` enum admits two.
- **`sha256sum` versus `shasum`.** Reuse the portable approach already in the
  project-key helper rather than writing a second one. Local green does not imply
  CI green; two CI-only failures in the 09-12 session were both macOS-versus-Linux.
- **Echo's silence is partly already fixed.** `echo.suite.skipped` landed on main
  in PR #329 but has never appeared on the bus, so the installed echo predates it.
  Some of echo's 424 silent fires will resolve on deploy. That does not overlap
  this signal — `suite.skipped` says "nothing this turn," `watch.unmatched` says
  "these patterns can never match here" — but it means echo's silence should not
  be read as evidence for this feature's effect after deploy.

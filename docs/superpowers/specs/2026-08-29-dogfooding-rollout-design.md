# Dogfooding the Onlooker marketplace stack

**Date:** 2026-08-29
**Tracking:** `ecosystem-449` (epic)
**Status:** Wave 0 re-baselined on ecosystem 0.45.2; Wave 1 retracted (`ecosystem-449.10`) and pending re-run; Waves 2–4 pending

## Problem

The repo publishes seventeen marketplace entries — the `ecosystem` substrate plus sixteen
plugins — and runs exactly one of them. Everything we know about how the stack behaves in a
real session comes from bats tests against synthetic payloads. Nobody has felt the latency,
the injected-context volume, or the token spend of the composed system.

The goal is threefold and staged: validate that a stranger's install path works, find bugs
under real use, and settle which plugins earn their keep day to day.

## Scope decisions

**Arena.** This repo only, enabled in the committed `.claude/settings.json`. Every contributor
to the marketplace repo gets the stack. For a repo whose entire premise is that these plugins
compose, running them on ourselves is the point.

**Source.** The GitHub-published marketplace, not the working tree. A local-path marketplace
would embed `/Users/<name>/src/...` in a committed file and fail to resolve for anyone else.
The cost is a slower loop: a fix needs merge → `/plugin marketplace update` → restart before
you feel it. That cost is accepted.

**Ordering.** Staged by hook cadence rather than by blocking risk. Attribution is the scarce
resource in a dogfooding exercise: ten plugins landing on `SessionStart` at once produces a
slow session start that nobody can attribute. Cadence maps directly to felt pain — startup
latency, per-turn tax, per-edit lag — and each wave isolates one failure mode.

## Wave 0 findings (complete)

**The gate contract works.** Every gate in the repo blocks by writing top-level
`{"decision":"block","reason":...}`, a shape the current hooks documentation no longer
describes; the docs specify only `hookSpecificOutput.permissionDecision`. A three-arm
experiment settled it empirically: the control arm created the file, the legacy
`decision:block` arm blocked it, and the modern `permissionDecision:deny` arm blocked it.
Compass, warden, and hard-mode governor are real gates, not silent no-ops.

That said, the gates depend on an undocumented shape that could be dropped without notice,
and the bats suite only asserts what a plugin writes to stdout — never that Claude Code
honors it — so the suite would stay green straight through that regression. Filed as
`ecosystem-449.1`.

**Latency baseline**, measured with only `ecosystem@0.44.0` enabled, best of three:

| Event | Hooks | Total |
|---|---|---|
| `SessionStart` | session-start-tracker 257ms, memory-recall-tracker 107ms | **~360ms** |
| `UserPromptSubmit` | turn-tracker 220ms, session-duration-tracker 132ms, prompt-rule-injector 90ms | **~442ms per turn** |
| `PostToolUse` | tool-history-tracker 180ms | **~180ms per edit** |

Every wave is measured against these numbers. Also stored as the `dogfood-wave0-baseline`
bd memory.

**The substrate already has a storage problem.** Before any wave lands, `~/.onlooker` is
829MB: `scribe/sessions` holds 37,403 files, `bursar/sessions` 31,744, `session-trackers`
37,454, `session-history` 33,019, `compass/sessions` 10,895, plus a 110MB `buffer.db` with a
9MB WAL. Flat directories, no sharding, no retention, no GC. Fifteen more plugins multiply the
write rate, and several scan their own session directories at `SessionStart`, so lookup cost
grows with history. Pre-existing rather than wave-induced, but dogfooding makes it acute.
Filed as `ecosystem-449.2`.

**Two smaller gaps.** `CLAUDE.md` claims compass has no implementation; it ships four hooks,
six libs, a calibrated config, and five bats files (`ecosystem-449.3`). And the committed
`.claude/settings.json` enables `ecosystem@onlooker-community` without declaring
`extraKnownMarketplaces`, so a fresh clone cannot resolve the marketplace at all — the
install path we are supposedly dogfooding is broken for everyone but the person who added
the marketplace by hand.

**Non-findings, checked and cleared.** `claude -p` works headlessly from a hook: the
interactive fish shell shadows `claude` with an account-picker function, but hooks run under
`sh`/`bash` and resolve the real `/opt/homebrew/bin/claude`. Ollama with `nomic-embed-text` is
installed, so historian's embedder has what it needs. All seventeen marketplace entries have
exact name parity with `plugins/` on disk.

## The waves

Each wave lands as one commit to `.claude/settings.json` **plus an explicit install of that
wave's plugins**, runs for a stated soak period, and ends with a measurement read against the
Wave 0 baseline. A wave does not advance until its exit criteria are met.

### Enabling is not installing

`enabledPlugins` does not install anything. It marks a plugin as enabled *if* it is installed.
Registration lives in `~/.claude-personal/plugins/installed_plugins.json`, and only
`claude plugin install` writes there. A wave committed to `.claude/settings.json` and nothing
else registers no hooks and measures nothing.

This is not a theoretical gap — it is what happened to Wave 1 (`ecosystem-449.10`). The
`autoUpdate` path is why it stayed invisible: it keeps the *cache* warm for every entry in
`enabledPlugins`, so all six plugins had freshly fetched version directories under
`plugins/cache/onlooker-community/` while five of them were absent from the install registry.
A cache check reads as healthy. Only the registry tells the truth.

So each wave needs an install step and a verification step:

```bash
# Install the wave's plugins. Scope must be passed explicitly.
claude plugin install <plugin>@onlooker-community --scope project

# Verify: every plugin the wave enables appears in the registry for this projectPath.
claude plugin list

# Restart, then confirm the hooks actually registered for the new session.
python3 ~/.onlooker/logs/hook-rollup.py <session-id>
```

`claude plugin update` has the same trap in a sharper form: it defaults to `--scope user` and
fails against a project-scoped plugin with `Plugin "<name>" is not installed at scope user`.
Every plugin command in this rollout needs `--scope project` passed explicitly.

**A wave is not live until a post-restart probe shows its plugins in `hook-health.jsonl`.**
Installing is necessary, not sufficient — hooks register at session start, so an install
performed mid-session changes nothing until the next one.

### Wave 1 — silent recorders

**Plugins:** lineage, inspector, assayer, echo, tribunal.

These add nothing to `SessionStart`. Lineage and inspector fire on `PostToolUse`; assayer,
echo, and tribunal on `Stop`. Tribunal's stop hook ships disabled by default and stays that
way — enabling the plugin here only registers it.

This wave also fixes the marketplace declaration, since without it the settings file does not
work for a fresh clone:

```json
{
  "extraKnownMarketplaces": {
    "onlooker-community": {
      "source": { "source": "github", "repo": "onlooker-community/ecosystem" }
    }
  },
  "enabledPlugins": {
    "ecosystem@onlooker-community": true,
    "lineage@onlooker-community": true,
    "inspector@onlooker-community": true,
    "assayer@onlooker-community": true,
    "echo@onlooker-community": true,
    "tribunal@onlooker-community": true
  }
}
```

`enabledPlugins` alone does not install anything. It marks a plugin enabled once the plugin
is present; a name listed there but never installed registers no hooks and reports no error.
Wave 1 sat in exactly that state — five of six entries enabled, one installed — and measured
nothing for a day before anyone noticed (ecosystem-449.10). Install each plugin explicitly,
then confirm against `~/.claude/plugins/installed_plugins.json` for this `projectPath`
before trusting a wave's numbers.

**Watch:** per-edit latency (baseline 180ms — lineage and inspector both land here, and
inspector shells out to the project's lint and typecheck), `Stop` latency, and whether
assayer and echo produce signal or noise on turns that changed nothing.

**Exit when:** a full working day of real sessions with per-edit latency under roughly 1s,
and lineage's ledger correctly answering `/lineage <file>:<line>` for a change made during
the soak.

### Wave 2 — the SessionStart/End cohort

**Plugins:** bursar, curator, archivist, librarian, counsel, cartographer, scribe.

This is the expensive wave and the reason for cadence-first ordering. Seven plugins land on
`SessionStart`, four of them shelling out to `claude -p` — a baseline of ~360ms will not
survive contact. Scribe also adds a `UserPromptSubmit` hook, and archivist adds `PreCompact`.

Land these **one per session, not as a block**, measuring each against the running total.
Order by expected cost, cheapest first: bursar, curator, scribe, archivist, librarian,
counsel, cartographer. Cartographer is last because its `SessionStart` audit is the single
most expensive hook in the set.

**Watch:** cumulative `SessionStart` wall time, and the volume of injected context — seven
plugins each contributing an "at a glance" line is its own context-budget problem, and it is
the failure mode most likely to make the stack feel bad rather than break.

**Exit when:** `SessionStart` stays under roughly 5s and total injected context under
roughly 2KB, or the offenders are configured down and re-measured.

### Wave 3 — per-prompt retrieval

**Plugins:** historian.

Historian is alone in this wave because it is the only plugin on the per-turn retrieval path:
it embeds every prompt and runs similarity search over stored chunks. It taxes the 442ms
`UserPromptSubmit` baseline on every single turn, which makes it the most latency-sensitive
plugin in the set and the one that most deserves isolated measurement.

Leave `session_archive.enabled` at its default `false` for the first sessions — turning on
`SessionEnd` transcript chunking before retrieval quality is understood adds storage to a
store that already has a retention problem.

**Watch:** per-turn latency delta, and whether retrieved chunks are actually relevant. A
retrieval layer that surfaces plausible-but-unrelated history is worse than none.

**Exit when:** per-turn overhead stays under roughly 1s and retrieved context is judged useful
more often than not across a day of sessions.

### Wave 4 — the gates

**Plugins:** warden, then compass, then governor promoted to hard enforcement.

Strictly one at a time, each with its own soak. Governor has not been enabled in any earlier
wave: it lands here at its default `enforcement: "soft"`, where it observes and reports
without blocking, and is promoted to `hard` only at the very end of the rollout.

**Warden first.** It blocks only after a detection fires, so a clean session never feels it.
The risk is false positives closing the content gate mid-task, which is recoverable via
`/warden clear`.

**Compass second**, and only after `ecosystem-449.1` is resolved. It is the most behaviorally
aggressive plugin in the set: it gates every write-class tool call, samples five Haiku
evaluators per check, and ships `error_policy: "closed"`, so its own errors block writes. The
circuit breaker opens after three consecutive failures and then fails open, so it degrades
rather than bricking the session — but the first soak should still run with
`error_policy: "open"` and only tighten once the false-positive rate is known.

**Governor to hard last.** Promoting enforcement is a one-line config change and the easiest
thing in the plan to revert.

**Watch:** false-positive rate above all. A gate that blocks correct work is worse than no
gate, and the whole point of ADR-001's prior-turn context is to suppress a specific
false-positive class — this wave is where that claim gets tested for real.

**Exit when:** each gate runs a full day with zero blocks the user disagreed with.

## Rollback

Every wave is one commit to one file. Rollback is `git revert` plus a session restart. If a
gate locks writes badly enough that editing the settings file is itself blocked, the
out-of-band escape is `claude --settings` with an override, or removing the plugin from
`~/.claude-personal/plugins/` directly — neither requires a working in-session write path.

## Where findings go

Beads, under epic `ecosystem-449`. Latency and spend measurements go in the wave's closing
comment on the epic. Anything worth surviving the session goes to `bd remember`, as the Wave 0
baseline already has.

## What this design deliberately does not do

No local-path marketplace, because it breaks the committed-settings goal. No global
enablement, though cross-project plugins like bursar and curator will show thinner signal
confined to one repo — that is an accepted cost of a tight blast radius, revisitable after
Wave 4. No fixing of `ecosystem-449.2` as part of the rollout: the storage problem is real and
filed, but coupling a substrate refactor to the rollout would make every wave's measurements
unattributable, which is the exact failure this ordering exists to prevent.

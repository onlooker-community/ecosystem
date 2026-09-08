# Recording which plugin version a session actually ran

**Date:** 2026-09-07
**Tracking:** `ecosystem-9eg` (under epic `ecosystem-449`)
**Status:** designed

## Problem

`/clear` mints a new `session_id` inside the **same** process, and plugin code is pinned at
process start, not session start. A cleared session therefore looks post-release by every
timestamp available while still running the pre-release plugin.

Measured 2026-09-07 while verifying `ecosystem-449.41`:

| Time (UTC) | Event |
|---|---|
| 16:33:41 | claude pid 96487 starts — pins lineage 0.5.0 |
| 17:34:17 | lineage 0.5.1 installed on disk |
| 18:15:30 | session `c8fc83ed` begins (`/clear` inside pid 96487) |
| 18:30:17 | `c8fc83ed` writes a ledger record — written by 0.5.0 |

The session's first event is 41 minutes *after* the install, so the previously documented
check — compare the session's first event timestamp to the install timestamp — reports "this
session runs 0.5.1". It ran 0.5.0.

Direct proof, captured during a live edit: the hook process was
`.../cache/onlooker-community/lineage/0.5.0/scripts/hooks/lineage-post-tool-use.sh`, parented
by pid 96487. Five claude processes were live in the checkout at once, four pre-install and
one post-install, all writing one ledger.

The root cause is not the check. It is that **nothing records the version**. There is no
event, no hook-health field, and no log line stating which plugin code a hook ran, so every
available answer is an inference from timestamps rather than an observation.

## Scope decisions

**Record the version; do not improve the proxy.** The bead's acceptance asks to re-document
the check as "process start time, not session first-event time". That is a better proxy, but
it is still a proxy, and it costs a detached `ps` watcher plus three tool calls to evaluate
once. Recording the version directly makes the whole timestamp comparison obsolete: there is
nothing to infer when the row says which code wrote it.

**Instrument the vendored lib, not `SessionStart`.** The bead proposed having hooks emit their
resolved `$CLAUDE_PLUGIN_ROOT` at `SessionStart`. Six plugins have no `SessionStart` hook —
assayer, echo, historian, inspector, lineage, tribunal — and that list includes lineage and
echo, the two plugins whose releases this bead exists to un-verify. The proposed fix would not
have caught either bug it was filed for. It also needs six new hooks and six new startup
latency contributions to reach strictly less coverage.

`hook-health.sh` is the opposite: it is vendored into every plugin, and
`test/bats/hook-health.bats` already enforces that every hook under
`plugins/*/scripts/hooks/*.sh` calls `hook_health_register`. The substrate reaches the same
code through `hook_register() { hook_health_register "$@"; }` in `validate-path.sh`. One edit
to the canonical lib, propagated by `scripts/sync-shared-libs.sh`, covers the substrate and
all sixteen plugins with no new hook surface.

**No schema change.** `hook-health.jsonl` is our own convention, written by `jq` directly and
not validated against `@onlooker-community/schema`. Extending the `session.start` payload
instead would hit `additionalProperties: false` in a **published** package, requiring a
release of the sibling `schema` repo and a dependency bump here, with this repo's
`ONLOOKER_VALIDATE=1` suites failing in between. Nothing in this bead needs that.

**Precedent.** `_hook_health_write` already stamps `lib_schema`, a content fingerprint of the
vendored lib, added by `ecosystem-449.31` for exactly this "one session, two copies" problem.
These fields sit beside it and answer the same class of question at plugin granularity.

## Design

### Fields

Three new keys on every `hook-health.jsonl` record:

| Field | Source | Null when |
|---|---|---|
| `plugin_name` | directory above the version in the lib's own path | path cannot be walked |
| `plugin_version` | version directory in the lib's own path | not a release layout (dev checkout) |
| `host_pid` | `$PPID` | never |

`plugin_version` is the observation the bead asks for. `host_pid` is what makes the mechanism
visible: two distinct `session_id` values sharing one `host_pid` **is** a `/clear`, and a
mixed-version window is a set of rows with one `plugin_name` and two `plugin_version` values.
Neither requires a process start timestamp, so no `ps` runs on the hot path.

### Self-location

The lib derives its own root from `${BASH_SOURCE[0]}`, the pattern CLAUDE.md already mandates
for `config-loader.sh`, and for the same reason: `$PLUGIN_ROOT` is read from whatever scope
did the sourcing and is lost in a sub-shell that inherits only `CLAUDE_PLUGIN_ROOT`.

The lib lives at `<root>/scripts/lib/hook-health.sh`, so `<root>` is the path with three
trailing components removed. Stripping uses pure parameter expansion (`${p%/*}`), never
`dirname "$(dirname ...)"` — CLAUDE.md records eighteen hand-rolled sites of that shape across
nine plugins, and zero of them were correct.

Two layouts must both work:

- **Released:** `.../cache/onlooker-community/lineage/0.5.1/scripts/lib/hook-health.sh`
  → root basename `0.5.1` matches `^[0-9]+\.[0-9]+\.[0-9]+`, so `plugin_version=0.5.1` and
  `plugin_name=lineage`.
- **Dev checkout:** `<repo>/plugins/lineage/scripts/lib/hook-health.sh`
  → root basename `lineage` is not a version, so `plugin_version=null` and
  `plugin_name=lineage`.

A null `plugin_version` honestly means "this row was written by an unreleased copy", which is
the right label for a working-tree run and distinguishes it from a released one. This mirrors
`duration_ms`, where null already means "could not be measured".

### Cost

Zero measurable overhead. Both derived values are computed once at source time by parameter
expansion; `$PPID` is a builtin. `_hook_health_write` already spawns one `jq`, and three more
`--arg` bindings do not add a process. This matters because the lib sits on the per-edit path
that wave 1's latency budget is gated on.

### Live read path

`scripts/session-plugin-versions.sh` answers "what is this session actually running" in one
call. It walks up the process tree from its own shell to the nearest `claude` ancestor, then
reports the distinct `plugin_name`/`plugin_version` pairs from `hook-health.jsonl` rows
carrying that `host_pid`. Because it reads observed rows rather than `installed_plugins.json`,
it reports what ran, not what is declared — which is the entire point of the bead.

## Testing

`test/bats/hook-health-plugin-version.bats`, new:

- released layout yields name and version
- dev-checkout layout yields name with null version
- unparseable path yields both null and still writes the row
- `host_pid` is present and equals the shell's parent
- fields survive the vendored copies, exercised from a copied-out standalone tree the way
  `config-lib-self-locating.bats` does

`scripts/sync-shared-libs.sh` re-stamps `_ONLOOKER_LIB_FINGERPRINT`, so
`shared-lib-fingerprint.bats` and `shared-lib-vendoring.bats` must both stay green.

## Out of scope

- Adding `source` (`startup`/`resume`/`clear`/`compact`) to the `session.start` payload. It
  would name the clear explicitly rather than leaving it inferable from a shared `host_pid`,
  but it needs the cross-repo schema release described above. Filed separately.
- Putting the version in the canonical event envelope so every bus event self-labels. More
  thorough, and probably right eventually, but it touches every event type and puts new work
  on the emitter's hot path.
- Re-running the contaminated measurements (`ecosystem-449.40` acceptance 7,
  `ecosystem-449.41`, `ecosystem-449.46`). Those are measurement tasks, not code, and are
  tracked on the bead itself.

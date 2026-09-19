# ADR-006: Hooks Mark Their Own Completion

**Status:** Accepted  
**Date:** 2026-09-18  
**Relates to:** [ADR-001](001-claude-code-hooks-as-integration-surface.md)

> **Rolled out in two changes.** The decision below is whole; the implementation is split
> because the two halves cannot land together safely. First the mechanism — the start
> breadcrumb, `run_id`, and `hook_health_complete`/`hook_health_exit` — with the EXIT trap
> still reporting as it always has. Then the conversion of every hook's exits, and only then
> the flip that makes an unmarked exit record `terminated`. Flipping first would label all 33
> hooks terminated on every fire; converting first would call a function that does not exist
> yet.

## Context

`scripts/lib/hook-health.sh` measured every hook by installing one trap:

```bash
trap '_hook_health_on_exit $?' EXIT
```

and branching on that exit code — `0` wrote `status=success`, anything else wrote `failure`.

**This reported a healthy hook throughout a total outage.** `librarian-session-end` accumulated **624 hook-health records on the development machine, every single one `status=success`**, while it was in fact being killed at the CLI's 1500ms SessionEnd deadline on nearly every session. The last 15 runs clustered at 1490–1524ms — a deadline, not a workload — against four runs that actually finished in 4000–5171ms. librarian did no work at all during that window and emitted no `scan.started`. The instrument said everything was fine.

The mechanism, reproduced directly: when a signal kills the shell, **bash still runs the EXIT trap**, but `$?` inside it is the status of the last *completed* command — typically a successful `jq`. So the trap saw `0` and wrote `success`.

This is substrate. `hook-health.sh` is vendored into all sixteen plugins, so the same false success applied to any hook the CLI cancels or kills. `duration_ms` was no fallback either: a killed hook's duration *is* the deadline, which reads as a slow-but-successful run. Nothing on the bus distinguished "ran to completion" from "was terminated."

Two repairs were measured and rejected.

**A signal trap alongside the EXIT trap** — the obvious fix — is worse than the bug. Bash defers a trapped signal while it waits on a foreground child. With a `TERM` trap installed and `sleep` in the foreground:

| signal target | handler ran at |
|---|---|
| pid only | **+9630 ms** |
| process group | +26 ms |

Untrapped, bash dies promptly in both. So installing a signal trap can make a hook **outlive the very deadline that killed it**, turning a clean 1500ms kill into a hook that runs on for the length of whatever child it was blocked on. It also cannot see `SIGKILL`.

**Inferring termination from `BASH_COMMAND`** inside the EXIT trap does not work. A hook killed mid-`sleep 30` reports `BASH_COMMAND=[sleep 30]`; a hook that fell off its own end reports `BASH_COMMAND=[jq -n 1 > /dev/null]`. Both are "a normal command, not an exit." The two cases are not separable from inside the dying shell.

Measured with no signal trap, the false success is also **universal, not mode-dependent**: signalled pid-only and signalled process-group both yield `$? == 0` in the EXIT trap.

## Decision

**The EXIT trap no longer guesses. The normal path marks itself, and absence means termination.** Two mechanisms, covering the two ways a hook dies:

- **`hook_health_complete` / `hook_health_exit`** — the hook states that it reached a termination point it chose. Without that mark the EXIT trap writes `status=terminated`, carrying the observed exit code as `last_exit_code=N` for forensics only. This covers `SIGTERM`, where the trap still runs. Once a hook has registered, **every path out of it must go through `hook_health_exit`**; `test/bats/hook-health.bats` enforces it, as the twin of the existing test that enforces `hook_health_register`.
- **A start breadcrumb** — `hook_health_register` writes a `status=started` record up front, carrying a `run_id` that the terminal record repeats. A breadcrumb whose `run_id` never appears on a terminal record is a run killed without any trap running. This covers `SIGKILL`, which no trap can see.

The `*_NESTED` re-entry guards are the one exception and keep a plain `exit`: they run *before* `hook-health.sh` is sourced, where `hook_health_exit` is undefined and calling it would exit 127 instead of 0. A guard that returns before registering is not a measured run.

## Rationale

**An instrument must not assert what it cannot observe.** The old trap inferred success from an exit code that provably carries no information about whether the hook finished. Recording `terminated` when completion was never marked states exactly what is known, and the failure direction is safe: a lost flag reads as terminated, never as a false success.

**The sentinel asks nothing of the dying shell.** Every reactive mechanism — signal traps, `BASH_COMMAND`, exit codes — needs the terminating process to cooperate at the moment it is being destroyed. Writing the breadcrumb up front removes that dependency entirely, which is why it holds for `SIGKILL` as well as `SIGTERM`.

**Positional beats reactive, and it is cheaper.** No signal trap means the hook's death semantics are unchanged: bash still dies promptly, and nothing can defer it. The completion mark is a variable assignment, and the breadcrumb is a single `printf` of already-computed values — no subprocess. Both bash paths stamp UTC for free (bash 4.2+ via the `printf %()T` builtin, bash 3.2 by asking the `jq` call the clock already made for both values).

**No schema change.** `hook-health.jsonl` is a local diagnostic log written directly by `jq`, not an event on the bus — `@onlooker-community/schema` has no hook-health surface. The new `started` and `terminated` statuses need no publish-and-bump cycle.

## Consequences

- **The log holds two lines per hook fire**, not one. `hook-rollup.mjs` excludes `status=started` from latency statistics explicitly rather than relying on the incidental fact that a breadcrumb carries no `session_id`.
- **A breadcrumb has no `session_id`**, because `hook_health_register` runs before the hook reads stdin. Orphaned starts are therefore counted across the whole log and reported as un-attributable to a session, rather than folded into per-session numbers where they would look like one.
- **107 termination sites across 33 registering hooks are converted** to `hook_health_exit`, in the second of the two changes above. The enforcing test means a new hook cannot quietly skip it. Fourteen sites are deliberately left as a plain `exit`: the `*_NESTED` guards, which run before the lib is sourced.
- **Records written before this change cannot be re-judged.** A breadcrumb with no `run_id` is unpairable in both directions, so it is not counted as orphaned; reading an outage out of old data would be its own false signal. The 624 known-bad librarian records stay as they are.
- **`hook_health_success` and `hook_health_failure` imply completion.** Both are statements that the hook reached a decision, so they set the flag before writing; otherwise every hook that writes its own record explicitly would report as terminated.

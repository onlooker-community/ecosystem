# ADR-003: Stop Hook as the Trigger Mechanism

**Status:** Accepted  
**Date:** 2026-05-24

## Context

Echo needs to know when an agent file has changed and run an evaluation. Several trigger points were considered:

- **Stop hook** — fires when a Claude Code session ends.
- **Pre-commit hook** — fires when the developer runs `git commit`.
- **PostToolUse hook** — fires after every tool call that writes a file.
- **CI step** — fires on push to a remote branch.
- **Manual `/echo` skill** — user-invoked on demand.

## Decision

Echo v0.1 uses the **Stop hook**.

## Rationale

**Correct granularity.** A session is the natural unit of prompt engineering work. A developer edits `tribunal-judge-standard.md`, tests it through several turns, and ends the session. That's the moment Echo should fire — after the work is done, not after each intermediate save.

**Claude Code already provides it.** The Stop hook is a first-class Claude Code hook type with a well-defined contract: the hook receives `{cwd, session_id}` on stdin and must exit 0 (or the session stop is blocked, which is why Echo always exits 0). No additional tooling or git hooks needed.

**Consistent with Tribunal's pattern.** Tribunal's Stop hook (when enabled) follows the same pattern — an advisory pass that fires at session end without blocking the stop. Echo mirrors this, which keeps the plugin model coherent across the ecosystem.

**No commit discipline required.** A pre-commit hook would only fire when the developer commits. Many prompt engineering workflows involve many experimental edits before any commit. Echo should capture signal on *any* session where a watched file changed, not only committed ones. Untracked and unstaged files are explicitly included in Echo's change detection.

**Low friction.** PostToolUse fires on every file write, which would run evaluations continuously mid-session — expensive, noisy, and disruptive. The Stop hook batches all changes from a session into a single suite run.

**Not CI.** CI integration has value but is a separate concern. A CI step can't write to `~/.onlooker/` on the developer's machine, and the baseline comparison is inherently local. Echo is a local development feedback tool; CI integration (e.g., posting drift to a PR comment) is a future feature.

## Consequences

- The recursion guard (`ECHO_NESTED=1`) is mandatory. `claude -p` spawns a subprocess that also triggers Stop, which would re-enter the hook infinitely. The guard must be set before any work begins and is checked as the very first statement.
- Echo cannot fire mid-session, so rapid iteration on a prompt file produces one signal per session, not one per edit. This is a feature for reducing noise, but means a long session with many edits only records the final state of each file.
- If a session ends without the developer saving changes (e.g., closed the terminal abruptly), the Stop hook may not fire. This is consistent with how all Stop hooks in Claude Code behave.
- Users who want on-demand evaluation can invoke Echo's logic manually by calling the hook directly. A future `/echo` skill could wrap this.
- The hook must be registered in `hooks.json` with `"matcher": "*"` so it fires on all sessions. Projects that want to opt out can set `echo.enabled: false` rather than removing the hook registration.

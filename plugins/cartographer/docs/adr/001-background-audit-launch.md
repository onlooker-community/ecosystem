# ADR-001: Background Audit Launch via nohup+setsid

**Status:** Accepted

## Context

Claude Code SessionStart hooks run synchronously and block session readiness until they exit. The Cartographer audit pipeline makes multiple `claude -p` calls and can take 1–10 minutes on large repos. Blocking the session for that duration is unacceptable.

## Decision

The SessionStart hook (`cartographer-session-start.sh`) performs only three fast operations before returning:
1. Read `last_audit_at` from a single JSON field.
2. Acquire a non-blocking lock (`flock -n` or PID-file fallback).
3. Launch `run-audit.sh` via `nohup setsid ... &`, then write the child PID and exit.

`nohup` prevents SIGHUP from reaching the child when the hook's process group is reaped. `setsid` creates a new session so the child is not in the hook's process group at all. Together they ensure the audit survives the hook exit.

## Consequences

- The hook returns in under 2 seconds regardless of repo size.
- Audit progress is visible only in `~/.onlooker/cartographer/<key>/audit.log`.
- The user has no immediate signal that an audit started; findings surface at the next `/cartographer` invocation or via event log consumers.

## Alternatives Considered

- **Synchronous with short timeout:** Limits audit depth; users would see partial results inconsistently.
- **Cron/launchd/systemd timer:** Requires out-of-process scheduler setup; breaks the "install the plugin, no other config required" contract.
- **PreCompact hook (like Archivist):** Archivist uses PreCompact because compaction is a natural checkpoint. Cartographer is file-change driven, not conversation-length driven — SessionStart is the better trigger.

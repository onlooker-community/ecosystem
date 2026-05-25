# ADR-002: flock with PID-File Fallback for Cross-Session Locking

**Status:** Accepted

## Context

Multiple Claude Code sessions can open in the same project directory simultaneously (multiple terminal windows, split panes, worktrees pointing to the same project key). Without coordination, concurrent sessions can each decide an audit is due and spawn competing `claude -p` subprocesses that race on `findings/<hash>.json` writes and `last_audit_at`.

## Decision

`cartographer-lock.sh` implements a two-tier lock:

1. **`flock --nonblock`** on `audit.lock` — kernel-level, atomic, preferred. Available on Linux without extra tooling.
2. **PID-file fallback** — reads PID from `audit.lock`, checks with `kill -0`. Used on macOS where `flock` requires `brew install flock` (coreutils) and may not be present.

Both tiers use non-blocking acquisition: the second session exits cleanly rather than queuing. The `/cartographer --force` flag kills the existing audit PID before acquiring the lock for manual override.

**Known limitation:** The PID-file fallback has a TOCTOU window between `kill -0` and writing the new PID. On single-machine developer workstations this is an acceptable risk; we are protecting against simultaneous sessions, not adversarial concurrent writes. This is documented in CLAUDE.md.

## Consequences

- Most Linux users get atomic kernel-level locking.
- macOS users without coreutils get a best-effort fallback with documented limitations.
- No mandatory external dependency beyond a standard shell.

## Alternatives Considered

- **Require `flock` as a mise dep:** Adds a dependency users must install; breaks the zero-config install story.
- **Use a socket/lockfile via `mkdir` (atomic on POSIX):** `mkdir` creates atomically; the lock is the directory existence. More portable than PID files but does not provide stale-lock recovery.
- **Accept duplicate concurrent audits:** Duplicate findings are eventually deduplicated by hash; correctness is preserved but wastes resources.

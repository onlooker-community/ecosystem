# Changelog

## [0.1.0] - 2026-05-25

### Added

- Initial plugin scaffold: `config.json`, `plugin.json`, `hooks.json`
- `governor-config.sh` — three-layer config resolution (plugin defaults → user settings → repo settings)
- `governor-events.sh` — canonical `governor.*` event emission via ecosystem `onlooker-event.mjs`
- `governor-ledger.sh` — JSONL ledger read/write with `portable-lock.sh` atomic guard
- `governor-estimate.sh` — tier-table token estimation with configurable safety margin
- `governor-session-start.sh` — SessionStart hook: setup storage, load budget contract, sweep stale locks, check global policy hash
- `governor-pre-tool-use.sh` — PreToolUse hook on Task: pre-call gate via check-and-reserve with `portable-lock.sh`
- `governor-post-tool-use.sh` — PostToolUse hook on Task: record call duration and estimated tokens to JSONL ledger
- `governor-stop.sh` — Stop hook: emit `governor.session.complete` with cumulative spend summary

# Changelog

All notable changes to the Cartographer plugin are documented here.

## [0.2.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.2.0...cartographer-v0.2.1) (2026-06-10)


### Bug Fixes

* vendor portable-lock.sh into cartographer and governor ([#73](https://github.com/onlooker-community/ecosystem/issues/73)) ([ab2c354](https://github.com/onlooker-community/ecosystem/commit/ab2c354b131c26cc642ebb51e84a043dc43cbaa1))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.1.0...cartographer-v0.2.0) (2026-05-25)


### Features

* **cartographer:** add proactive instruction-file audit plugin :mag: ([#35](https://github.com/onlooker-community/ecosystem/issues/35)) ([387d00a](https://github.com/onlooker-community/ecosystem/commit/387d00ad04da5aae91048254ad0526bb674ed498))

## [0.1.0](https://github.com/onlooker-community/ecosystem/releases/tag/cartographer-v0.1.0) (2026-05-25)

### Added

- SessionStart hook with interval gate and non-blocking background audit launch (`nohup setsid`)
- PostToolUse hook on Write/Edit/MultiEdit with exact `basename(realpath(...))` matching for CLAUDE.md files
- Five-phase audit pipeline: discover → extract → relate → synthesize → emit
- LLM-assisted analysis for contradictions, stale references, dead rules, and scope collisions
- `flock`-based cross-session audit lock with PID-file fallback for macOS
- Commutative `finding_hash` (SHA256) for stable finding identity across audit runs
- Atomic finding writes (`*.tmp` + `mv -f`) and `dedup/<hash>` sentinel store
- At-least-once `cartographer.issue.found` event delivery; documented dedup contract
- `/cartographer` skill with `--verbose`, `--status`, `--force`, `--scope`, and `--phase` flags
- Four ADRs documenting key design decisions
- Default `exclude_paths` covering `node_modules`, `.git`, `vendor`, `.venv`, and common build dirs
- `enabled: false` default — opt-in activation via `.claude/settings.json`

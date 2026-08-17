# Changelog

All notable changes to the Cartographer plugin are documented here.

## [0.4.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.4.0...cartographer-v0.4.1) (2026-08-17)


### Bug Fixes

* **cartographer:** put its events on the bus for the first time :mega: ([#170](https://github.com/onlooker-community/ecosystem/issues/170)) ([91be8d2](https://github.com/onlooker-community/ecosystem/commit/91be8d2c9f171006db12842f3e582d001f9d4e27))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.3.1...cartographer-v0.4.0) (2026-08-16)


### Features

* **cartographer:** detect what no instruction file mentions :eyes: ([#168](https://github.com/onlooker-community/ecosystem/issues/168)) ([31efb7b](https://github.com/onlooker-community/ecosystem/commit/31efb7b035665d5a49a37c1e1af21f519850f7bd))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.3.0...cartographer-v0.3.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.2.1...cartographer-v0.3.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

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

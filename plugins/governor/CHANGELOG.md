# Changelog

## [0.3.2](https://github.com/onlooker-community/ecosystem/compare/governor-v0.3.1...governor-v0.3.2) (2026-08-02)


### Bug Fixes

* librarian + bursar + governor improvements ([#119](https://github.com/onlooker-community/ecosystem/issues/119)) ([d7cdab5](https://github.com/onlooker-community/ecosystem/commit/d7cdab528ea5181ea35da68fbc5ad2e5b064abea))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/governor-v0.3.0...governor-v0.3.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/governor-v0.2.1...governor-v0.3.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

## [0.2.1](https://github.com/onlooker-community/ecosystem/compare/governor-v0.2.0...governor-v0.2.1) (2026-06-10)


### Bug Fixes

* vendor portable-lock.sh into cartographer and governor ([#73](https://github.com/onlooker-community/ecosystem/issues/73)) ([ab2c354](https://github.com/onlooker-community/ecosystem/commit/ab2c354b131c26cc642ebb51e84a043dc43cbaa1))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/governor-v0.1.0...governor-v0.2.0) (2026-05-26)


### Features

* **governor:** resource governance and budget enforcement plugin :rocket: ([#43](https://github.com/onlooker-community/ecosystem/issues/43)) ([04e6d70](https://github.com/onlooker-community/ecosystem/commit/04e6d7051f27db752bb121d389d65b4d8ade04ad))

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

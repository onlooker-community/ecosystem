# Changelog

## [0.4.7](https://github.com/onlooker-community/ecosystem/compare/governor-v0.4.6...governor-v0.4.7) (2026-09-06)


### Bug Fixes

* **events:** emit through the newest ecosystem, not the first one listed :satellite: ([#276](https://github.com/onlooker-community/ecosystem/issues/276)) ([1b3541c](https://github.com/onlooker-community/ecosystem/commit/1b3541c8bbeaf9c00a992ee339e2a726fa9e087c))

## [0.4.6](https://github.com/onlooker-community/ecosystem/compare/governor-v0.4.5...governor-v0.4.6) (2026-09-05)


### Bug Fixes

* **hooks:** attribute nested sessions to their own id :straight_ruler: ([#252](https://github.com/onlooker-community/ecosystem/issues/252)) ([74b34ec](https://github.com/onlooker-community/ecosystem/commit/74b34ecdc038d1e90b7a236077601ea1b6ec9ee8))

## [0.4.5](https://github.com/onlooker-community/ecosystem/compare/governor-v0.4.4...governor-v0.4.5) (2026-09-03)


### Bug Fixes

* **config:** honor CLAUDE_CONFIG_DIR for user settings :mag: ([#237](https://github.com/onlooker-community/ecosystem/issues/237)) ([057a40d](https://github.com/onlooker-community/ecosystem/commit/057a40d65d221dadef9d6fda235c87e032375235))

## [0.4.4](https://github.com/onlooker-community/ecosystem/compare/governor-v0.4.3...governor-v0.4.4) (2026-09-02)


### Bug Fixes

* **lock:** break the abandoned locks reclamation was built for :relieved: ([#233](https://github.com/onlooker-community/ecosystem/issues/233)) ([887e227](https://github.com/onlooker-community/ecosystem/commit/887e227c7f68c379e1ade239e9e9e322e7b2ce35))

## [0.4.3](https://github.com/onlooker-community/ecosystem/compare/governor-v0.4.2...governor-v0.4.3) (2026-09-01)


### Bug Fixes

* **lock:** reclaim a lock whose holder was killed :relieved: ([#227](https://github.com/onlooker-community/ecosystem/issues/227)) ([32bde03](https://github.com/onlooker-community/ecosystem/commit/32bde034bbb70d5f85120abceea2cfa337526d12))

## [0.4.2](https://github.com/onlooker-community/ecosystem/compare/governor-v0.4.1...governor-v0.4.2) (2026-08-30)


### Bug Fixes

* **hook-health:** register before sourcing so spans are comparable :straight_ruler: ([#217](https://github.com/onlooker-community/ecosystem/issues/217)) ([20e620a](https://github.com/onlooker-community/ecosystem/commit/20e620a0aacf018993130e05749e8b4e6199726c))

## [0.4.1](https://github.com/onlooker-community/ecosystem/compare/governor-v0.4.0...governor-v0.4.1) (2026-08-30)


### Bug Fixes

* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/governor-v0.3.5...governor-v0.4.0) (2026-08-29)


### Features

* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))

## [0.3.5](https://github.com/onlooker-community/ecosystem/compare/governor-v0.3.4...governor-v0.3.5) (2026-08-29)


### Bug Fixes

* **gates:** emit the documented permissionDecision deny shape :shield: ([#211](https://github.com/onlooker-community/ecosystem/issues/211)) ([c68e758](https://github.com/onlooker-community/ecosystem/commit/c68e758c48fbfe1359435ef7143724e3686968e2))

## [0.3.4](https://github.com/onlooker-community/ecosystem/compare/governor-v0.3.3...governor-v0.3.4) (2026-08-29)


### Bug Fixes

* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))

## [0.3.3](https://github.com/onlooker-community/ecosystem/compare/governor-v0.3.2...governor-v0.3.3) (2026-08-22)


### Bug Fixes

* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))

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

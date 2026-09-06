# Changelog

## [0.4.7](https://github.com/onlooker-community/ecosystem/compare/echo-v0.4.6...echo-v0.4.7) (2026-09-06)


### Bug Fixes

* **events:** emit through the newest ecosystem, not the first one listed :satellite: ([#276](https://github.com/onlooker-community/ecosystem/issues/276)) ([1b3541c](https://github.com/onlooker-community/ecosystem/commit/1b3541c8bbeaf9c00a992ee339e2a726fa9e087c))

## [0.4.6](https://github.com/onlooker-community/ecosystem/compare/echo-v0.4.5...echo-v0.4.6) (2026-09-06)


### Bug Fixes

* **echo:** watch the tree the session worked in, and grade the right copy :eyes: ([#268](https://github.com/onlooker-community/ecosystem/issues/268)) ([e6650bb](https://github.com/onlooker-community/ecosystem/commit/e6650bb98301a865477dbc88288f3ecb008dc4f6))

## [0.4.5](https://github.com/onlooker-community/ecosystem/compare/echo-v0.4.4...echo-v0.4.5) (2026-09-05)


### Bug Fixes

* **hooks:** attribute nested sessions to their own id :straight_ruler: ([#252](https://github.com/onlooker-community/ecosystem/issues/252)) ([74b34ec](https://github.com/onlooker-community/ecosystem/commit/74b34ecdc038d1e90b7a236077601ea1b6ec9ee8))

## [0.4.4](https://github.com/onlooker-community/ecosystem/compare/echo-v0.4.3...echo-v0.4.4) (2026-09-03)


### Bug Fixes

* **defaults:** ship path defaults that match repos other than this one :broom: ([#241](https://github.com/onlooker-community/ecosystem/issues/241)) ([aa44b98](https://github.com/onlooker-community/ecosystem/commit/aa44b98b320ab88208481b094f8f8032921fdd71))


### Performance Improvements

* **clock:** stop paying python3 to ask what time it is :zap: ([#239](https://github.com/onlooker-community/ecosystem/issues/239)) ([2be081c](https://github.com/onlooker-community/ecosystem/commit/2be081c36ac7dd907ca55ce49bba51764aeb4396))

## [0.4.3](https://github.com/onlooker-community/ecosystem/compare/echo-v0.4.2...echo-v0.4.3) (2026-09-03)


### Bug Fixes

* **config:** honor CLAUDE_CONFIG_DIR for user settings :mag: ([#237](https://github.com/onlooker-community/ecosystem/issues/237)) ([057a40d](https://github.com/onlooker-community/ecosystem/commit/057a40d65d221dadef9d6fda235c87e032375235))

## [0.4.2](https://github.com/onlooker-community/ecosystem/compare/echo-v0.4.1...echo-v0.4.2) (2026-08-30)


### Bug Fixes

* **hook-health:** register before sourcing so spans are comparable :straight_ruler: ([#217](https://github.com/onlooker-community/ecosystem/issues/217)) ([20e620a](https://github.com/onlooker-community/ecosystem/commit/20e620a0aacf018993130e05749e8b4e6199726c))

## [0.4.1](https://github.com/onlooker-community/ecosystem/compare/echo-v0.4.0...echo-v0.4.1) (2026-08-30)


### Bug Fixes

* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/echo-v0.3.3...echo-v0.4.0) (2026-08-29)


### Features

* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))

## [0.3.3](https://github.com/onlooker-community/ecosystem/compare/echo-v0.3.2...echo-v0.3.3) (2026-08-29)


### Bug Fixes

* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))

## [0.3.2](https://github.com/onlooker-community/ecosystem/compare/echo-v0.3.1...echo-v0.3.2) (2026-08-22)


### Bug Fixes

* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/echo-v0.3.0...echo-v0.3.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/echo-v0.2.0...echo-v0.3.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/echo-v0.1.0...echo-v0.2.0) (2026-05-25)


### Features

* **echo:** add prompt regression detection plugin ([#32](https://github.com/onlooker-community/ecosystem/issues/32)) ([65274d4](https://github.com/onlooker-community/ecosystem/commit/65274d4d8326950d6c998ca292fed13b1b8c493b))

## [Unreleased]

### Added

- Initial plugin scaffold: `echo-stop-gate.sh` Stop hook
- Config schema (`config.json`) with `watch_paths`, `exclude_paths`, `drift_threshold`, and `evaluation` model settings
- `echo-config.sh`: config loading with `.claude/settings.json` override support
- `echo-events.sh`: canonical `echo.*` event emission via `onlooker-event.mjs`
- `echo-project-key.sh`: stable project key and test_id derivation
- `echo-ulid.sh`: ULID generator for suite and test identifiers
- Recursion guard (`ECHO_NESTED=1`) preventing subprocess re-entry
- Baseline storage under `~/.onlooker/echo/<project-key>/baselines/`
- Emits `echo.suite.started`, `echo.improvement.detected`, `echo.regression.detected`, `echo.suite.complete` against schema v2.2.0
- `merge_recommended` derived from absence of regressions
- `drift`, `baseline_score`, `score_after`, `drift_threshold` populated on `echo.suite.complete` when a prior baseline exists

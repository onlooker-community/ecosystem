# Changelog

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

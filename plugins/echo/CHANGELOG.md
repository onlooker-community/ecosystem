# Changelog

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

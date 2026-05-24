# Changelog

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

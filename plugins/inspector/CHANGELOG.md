# Changelog

## [0.4.4](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.4.3...inspector-v0.4.4) (2026-09-05)


### Bug Fixes

* **hooks:** attribute nested sessions to their own id :straight_ruler: ([#252](https://github.com/onlooker-community/ecosystem/issues/252)) ([74b34ec](https://github.com/onlooker-community/ecosystem/commit/74b34ecdc038d1e90b7a236077601ea1b6ec9ee8))

## [0.4.3](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.4.2...inspector-v0.4.3) (2026-09-03)


### Performance Improvements

* **clock:** stop paying python3 to ask what time it is :zap: ([#239](https://github.com/onlooker-community/ecosystem/issues/239)) ([2be081c](https://github.com/onlooker-community/ecosystem/commit/2be081c36ac7dd907ca55ce49bba51764aeb4396))

## [0.4.2](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.4.1...inspector-v0.4.2) (2026-09-03)


### Bug Fixes

* **config:** honor CLAUDE_CONFIG_DIR for user settings :mag: ([#237](https://github.com/onlooker-community/ecosystem/issues/237)) ([057a40d](https://github.com/onlooker-community/ecosystem/commit/057a40d65d221dadef9d6fda235c87e032375235))

## [0.4.1](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.4.0...inspector-v0.4.1) (2026-08-30)


### Bug Fixes

* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.3.5...inspector-v0.4.0) (2026-08-29)


### Features

* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))

## [0.3.5](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.3.4...inspector-v0.3.5) (2026-08-29)


### Bug Fixes

* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))

## [0.3.4](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.3.3...inspector-v0.3.4) (2026-08-22)


### Bug Fixes

* **inspector:** canonicalize the file and repo root the same way :mag: ([0f850e9](https://github.com/onlooker-community/ecosystem/commit/0f850e92d7e620e4d7e06f512ef81efe4255f316))

## [0.3.3](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.3.2...inspector-v0.3.3) (2026-08-22)


### Bug Fixes

* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))

## [0.3.2](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.3.1...inspector-v0.3.2) (2026-08-02)


### Bug Fixes

* restore config convenience functions & refactor execution plugins to shared loader ([#128](https://github.com/onlooker-community/ecosystem/issues/128)) ([4b3660c](https://github.com/onlooker-community/ecosystem/commit/4b3660c5a8b234187ec1e71c37b63e6a3d305c98))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.3.0...inspector-v0.3.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.2.0...inspector-v0.3.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/inspector-v0.1.0...inspector-v0.2.0) (2026-06-15)


### Features

* **inspector:** ship the per-edit lint/typecheck plugin ([#88](https://github.com/onlooker-community/ecosystem/issues/88)) ([2018243](https://github.com/onlooker-community/ecosystem/commit/201824384abd6a4fc5f4395266924aa413a2ffd1))

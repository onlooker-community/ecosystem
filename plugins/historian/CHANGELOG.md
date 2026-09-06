# Changelog

## [0.4.8](https://github.com/onlooker-community/ecosystem/compare/historian-v0.4.7...historian-v0.4.8) (2026-09-06)


### Bug Fixes

* **emit:** default the sink instead of falling silent :loud_sound: ([#278](https://github.com/onlooker-community/ecosystem/issues/278)) ([1f4c0f9](https://github.com/onlooker-community/ecosystem/commit/1f4c0f9849a03ea610ebba5718ab986cb122246e))

## [0.4.7](https://github.com/onlooker-community/ecosystem/compare/historian-v0.4.6...historian-v0.4.7) (2026-09-06)


### Bug Fixes

* **events:** emit through the newest ecosystem, not the first one listed :satellite: ([#276](https://github.com/onlooker-community/ecosystem/issues/276)) ([1b3541c](https://github.com/onlooker-community/ecosystem/commit/1b3541c8bbeaf9c00a992ee339e2a726fa9e087c))

## [0.4.6](https://github.com/onlooker-community/ecosystem/compare/historian-v0.4.5...historian-v0.4.6) (2026-09-06)


### Bug Fixes

* **emit:** stop doubling the path that silenced three plugins :relieved: ([#261](https://github.com/onlooker-community/ecosystem/issues/261)) ([ae9c6a8](https://github.com/onlooker-community/ecosystem/commit/ae9c6a8aca309737e03028d1182cf2d4dcf39acb))

## [0.4.5](https://github.com/onlooker-community/ecosystem/compare/historian-v0.4.4...historian-v0.4.5) (2026-09-05)


### Bug Fixes

* **hooks:** attribute nested sessions to their own id :straight_ruler: ([#252](https://github.com/onlooker-community/ecosystem/issues/252)) ([74b34ec](https://github.com/onlooker-community/ecosystem/commit/74b34ecdc038d1e90b7a236077601ea1b6ec9ee8))

## [0.4.4](https://github.com/onlooker-community/ecosystem/compare/historian-v0.4.3...historian-v0.4.4) (2026-09-03)


### Performance Improvements

* **clock:** stop paying python3 to ask what time it is :zap: ([#239](https://github.com/onlooker-community/ecosystem/issues/239)) ([2be081c](https://github.com/onlooker-community/ecosystem/commit/2be081c36ac7dd907ca55ce49bba51764aeb4396))

## [0.4.3](https://github.com/onlooker-community/ecosystem/compare/historian-v0.4.2...historian-v0.4.3) (2026-09-03)


### Bug Fixes

* **config:** honor CLAUDE_CONFIG_DIR for user settings :mag: ([#237](https://github.com/onlooker-community/ecosystem/issues/237)) ([057a40d](https://github.com/onlooker-community/ecosystem/commit/057a40d65d221dadef9d6fda235c87e032375235))

## [0.4.2](https://github.com/onlooker-community/ecosystem/compare/historian-v0.4.1...historian-v0.4.2) (2026-08-30)


### Bug Fixes

* **hook-health:** register before sourcing so spans are comparable :straight_ruler: ([#217](https://github.com/onlooker-community/ecosystem/issues/217)) ([20e620a](https://github.com/onlooker-community/ecosystem/commit/20e620a0aacf018993130e05749e8b4e6199726c))

## [0.4.1](https://github.com/onlooker-community/ecosystem/compare/historian-v0.4.0...historian-v0.4.1) (2026-08-30)


### Bug Fixes

* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/historian-v0.3.5...historian-v0.4.0) (2026-08-29)


### Features

* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))

## [0.3.5](https://github.com/onlooker-community/ecosystem/compare/historian-v0.3.4...historian-v0.3.5) (2026-08-29)


### Bug Fixes

* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))

## [0.3.4](https://github.com/onlooker-community/ecosystem/compare/historian-v0.3.3...historian-v0.3.4) (2026-08-22)


### Bug Fixes

* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))

## [0.3.3](https://github.com/onlooker-community/ecosystem/compare/historian-v0.3.2...historian-v0.3.3) (2026-08-10)


### Bug Fixes

* make the local bats suite tell the truth :mag: ([#135](https://github.com/onlooker-community/ecosystem/issues/135)) ([f0763e0](https://github.com/onlooker-community/ecosystem/commit/f0763e09f3caf2d39c89f28befd12567af0af845))

## [0.3.2](https://github.com/onlooker-community/ecosystem/compare/historian-v0.3.1...historian-v0.3.2) (2026-08-01)


### Bug Fixes

* **historian:** export CLAUDE_PLUGIN_ROOT so config loads correctly :bug: ([#112](https://github.com/onlooker-community/ecosystem/issues/112)) ([f24b0b4](https://github.com/onlooker-community/ecosystem/commit/f24b0b4375c64385fefd329cd07d8874785002e9))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/historian-v0.3.0...historian-v0.3.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/historian-v0.2.1...historian-v0.3.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

## [0.2.1](https://github.com/onlooker-community/ecosystem/compare/historian-v0.2.0...historian-v0.2.1) (2026-06-28)


### Performance Improvements

* **historian:** fix O(n²) chunk loop and embedder false-positive :relieved: ([4ef130a](https://github.com/onlooker-community/ecosystem/commit/4ef130a4c01ec378da5b4d8baeeb7b4fb6059272))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/historian-v0.1.0...historian-v0.2.0) (2026-06-04)


### Features

* **historian:** retrieval pipeline + ollama embedder :telescope: ([#61](https://github.com/onlooker-community/ecosystem/issues/61)) ([7eae752](https://github.com/onlooker-community/ecosystem/commit/7eae752a288c4678ab093042469f2e65d428f0d9))

## [0.1.0](https://github.com/onlooker-community/ecosystem/compare/historian-v0.0.1...historian-v0.1.0) (2026-06-04)


### Features

* **historian:** introduce SessionEnd indexing :spiral_notepad: ([#59](https://github.com/onlooker-community/ecosystem/issues/59)) ([dd6c7f6](https://github.com/onlooker-community/ecosystem/commit/dd6c7f6ea872437cab6b16de50838dfc72750c7b))

## Changelog

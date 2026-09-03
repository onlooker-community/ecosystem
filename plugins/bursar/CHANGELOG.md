# Changelog

## [0.4.5](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.4.4...bursar-v0.4.5) (2026-09-03)


### Performance Improvements

* **clock:** stop paying python3 to ask what time it is :zap: ([#239](https://github.com/onlooker-community/ecosystem/issues/239)) ([2be081c](https://github.com/onlooker-community/ecosystem/commit/2be081c36ac7dd907ca55ce49bba51764aeb4396))

## [0.4.4](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.4.3...bursar-v0.4.4) (2026-09-03)


### Bug Fixes

* **config:** honor CLAUDE_CONFIG_DIR for user settings :mag: ([#237](https://github.com/onlooker-community/ecosystem/issues/237)) ([057a40d](https://github.com/onlooker-community/ecosystem/commit/057a40d65d221dadef9d6fda235c87e032375235))

## [0.4.3](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.4.2...bursar-v0.4.3) (2026-09-02)


### Bug Fixes

* **lock:** break the abandoned locks reclamation was built for :relieved: ([#233](https://github.com/onlooker-community/ecosystem/issues/233)) ([887e227](https://github.com/onlooker-community/ecosystem/commit/887e227c7f68c379e1ade239e9e9e322e7b2ce35))

## [0.4.2](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.4.1...bursar-v0.4.2) (2026-09-01)


### Bug Fixes

* **lock:** reclaim a lock whose holder was killed :relieved: ([#227](https://github.com/onlooker-community/ecosystem/issues/227)) ([32bde03](https://github.com/onlooker-community/ecosystem/commit/32bde034bbb70d5f85120abceea2cfa337526d12))

## [0.4.1](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.4.0...bursar-v0.4.1) (2026-08-30)


### Bug Fixes

* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.3.2...bursar-v0.4.0) (2026-08-29)


### Features

* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))

## [0.3.2](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.3.1...bursar-v0.3.2) (2026-08-29)


### Bug Fixes

* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.3.0...bursar-v0.3.1) (2026-08-22)


### Bug Fixes

* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.2.2...bursar-v0.3.0) (2026-08-02)


### Features

* **config:** add shared config loader supporting all five settings layers :sparkles: ([#123](https://github.com/onlooker-community/ecosystem/issues/123)) ([c048b76](https://github.com/onlooker-community/ecosystem/commit/c048b76bee2b39abeb7f1af77181191dd48f9cf5))


### Bug Fixes

* **hooks:** prevent SessionEnd timeouts causing breadcrumb accumulation ([#121](https://github.com/onlooker-community/ecosystem/issues/121)) ([3c7a409](https://github.com/onlooker-community/ecosystem/commit/3c7a40937aa3ea8c1db85dd0bb3fcc22589bbb49))

## [0.2.2](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.2.1...bursar-v0.2.2) (2026-08-02)


### Bug Fixes

* librarian conflict detection + bursar rollup lock timeout ([#117](https://github.com/onlooker-community/ecosystem/issues/117)) ([16180a2](https://github.com/onlooker-community/ecosystem/commit/16180a210a6f0561c09b77a2b102849f63f1e730))

## [0.2.1](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.2.0...bursar-v0.2.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.1.1...bursar-v0.2.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

## [0.1.1](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.1.0...bursar-v0.1.1) (2026-06-24)


### Performance Improvements

* **bursar:** collapse process forks in SessionEnd hot path :relieved: ([#101](https://github.com/onlooker-community/ecosystem/issues/101)) ([7a426fe](https://github.com/onlooker-community/ecosystem/commit/7a426fe359785eca35ea1ad61523b05fda79e0da))

## [0.1.0](https://github.com/onlooker-community/ecosystem/compare/bursar-v0.0.1...bursar-v0.1.0) (2026-06-12)


### Features

* **bursar:** introduce multi-session budget rollup plugin ([#81](https://github.com/onlooker-community/ecosystem/issues/81)) ([b11e687](https://github.com/onlooker-community/ecosystem/commit/b11e687744bab70a94025c46c4aaa58fb7ea97f4))

## Changelog

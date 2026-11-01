# Changelog

## [0.12.2](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.12.1...counsel-v0.12.2) (2026-11-01)


### Bug Fixes

* **skills:** give skill runs their real session ID :label: ([#529](https://github.com/onlooker-community/ecosystem/issues/529)) ([39a435c](https://github.com/onlooker-community/ecosystem/commit/39a435cc5f6f2d6e6897f0bb049aab4914e3d61f))

## [0.12.1](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.12.0...counsel-v0.12.1) (2026-11-01)


### Bug Fixes

* **skills:** make skill shell blocks run from the tool shell :shell: ([#527](https://github.com/onlooker-community/ecosystem/issues/527)) ([dbbaee2](https://github.com/onlooker-community/ecosystem/commit/dbbaee23a28e1d6c3853b6b4d44ff00410503388))

## [0.12.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.11.1...counsel-v0.12.0) (2026-10-26)


### Features

* **customs:** ask before a secret leaves for the wrong host :passport_control: ([#506](https://github.com/onlooker-community/ecosystem/issues/506)) ([7cb89b5](https://github.com/onlooker-community/ecosystem/commit/7cb89b5551f13fed50aec93a34556c6d951aa93c))

## [0.11.1](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.11.0...counsel-v0.11.1) (2026-10-25)


### Bug Fixes

* **plugins:** run every nested claude -p with hooks off :scissors: ([#494](https://github.com/onlooker-community/ecosystem/issues/494)) ([c6f4123](https://github.com/onlooker-community/ecosystem/commit/c6f4123f56ba63ff72bf2d17ac6b91fca4e5e349))

## [0.11.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.10.2...counsel-v0.11.0) (2026-10-14)


### Features

* **config:** add a validating integer accessor :shield: ([#415](https://github.com/onlooker-community/ecosystem/issues/415)) ([879969e](https://github.com/onlooker-community/ecosystem/commit/879969ecc01cf1e293135d52c77aab4985575221))
* **counsel:** add /counsel on-demand weekly-review command :rocket: ([#76](https://github.com/onlooker-community/ecosystem/issues/76)) ([8ce951c](https://github.com/onlooker-community/ecosystem/commit/8ce951cd5cb7b173f194f86c2960a31fb0d6889d))
* **counsel:** weekly observability synthesis and coaching brief :robot: ([#51](https://github.com/onlooker-community/ecosystem/issues/51)) ([6364586](https://github.com/onlooker-community/ecosystem/commit/63645863cf3a1d7bbf0353aacb9b71e4f977dd56))
* **ecosystem:** stamp the plugin version each session actually runs :mag: ([#305](https://github.com/onlooker-community/ecosystem/issues/305)) ([d58361d](https://github.com/onlooker-community/ecosystem/commit/d58361dbd22909d683087e1a0dde1d644cff6e42))
* **envelope:** attribute every event to a repository :world_map: ([#435](https://github.com/onlooker-community/ecosystem/issues/435)) ([ab3fe4d](https://github.com/onlooker-community/ecosystem/commit/ab3fe4d1fd2c6f11d1284a8515efed732ef2aafb))
* **hook-health:** let a record say which vendored copy wrote it :fingerprint: ([#290](https://github.com/onlooker-community/ecosystem/issues/290)) ([37bdbe5](https://github.com/onlooker-community/ecosystem/commit/37bdbe55ec5a01ece82c34dfc8ee95a6c2eda64b))
* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))
* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))
* **plugins:** persist structured JSON and emit onlooker.artifact.ready :outbox_tray: ([#103](https://github.com/onlooker-community/ecosystem/issues/103)) ([9b689a4](https://github.com/onlooker-community/ecosystem/commit/9b689a41aa4bdb481fef93b484e6446da731e8f1))


### Bug Fixes

* **config:** honor CLAUDE_CONFIG_DIR for user settings :mag: ([#237](https://github.com/onlooker-community/ecosystem/issues/237)) ([057a40d](https://github.com/onlooker-community/ecosystem/commit/057a40d65d221dadef9d6fda235c87e032375235))
* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))
* **config:** resolve settings roots in the loader, not at call sites :compass: ([#327](https://github.com/onlooker-community/ecosystem/issues/327)) ([50c5687](https://github.com/onlooker-community/ecosystem/commit/50c56873299401296a6ba6436adba3d56477f331))
* **counsel:** describe the whole window, sample its recent end :telescope: ([#442](https://github.com/onlooker-community/ecosystem/issues/442)) ([3794f5b](https://github.com/onlooker-community/ecosystem/commit/3794f5b3c43f505cd329fb7074b2b2957ffa5215))
* **counsel:** drop unsupported --max-tokens flag from claude synthesis call :relieved: ([#79](https://github.com/onlooker-community/ecosystem/issues/79)) ([ade85ce](https://github.com/onlooker-community/ecosystem/commit/ade85cecb3243781f47e14fea4990ce31e69e8f4))
* **counsel:** map every shipped plugin to a signal class :telescope: ([#441](https://github.com/onlooker-community/ecosystem/issues/441)) ([1967ad1](https://github.com/onlooker-community/ecosystem/commit/1967ad109abfd5d06efa4a9a6cc31c594679d80f))
* **counsel:** stop pipefail from discarding all events on large logs :relieved: ([#78](https://github.com/onlooker-community/ecosystem/issues/78)) ([638347d](https://github.com/onlooker-community/ecosystem/commit/638347dec3b9df740b7a85c3e475fa2ffe5d054b))
* **ecosystem:** let each hook keep its own name in the health log :mag: ([#309](https://github.com/onlooker-community/ecosystem/issues/309)) ([de701bf](https://github.com/onlooker-community/ecosystem/commit/de701bf958134709d0884aef018619c685b227de))
* **events:** emit through the newest ecosystem, not the first one listed :satellite: ([#276](https://github.com/onlooker-community/ecosystem/issues/276)) ([1b3541c](https://github.com/onlooker-community/ecosystem/commit/1b3541c8bbeaf9c00a992ee339e2a726fa9e087c))
* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))
* **hook-health:** see the runs that die without a trap :footprints: ([#341](https://github.com/onlooker-community/ecosystem/issues/341)) ([92a1a59](https://github.com/onlooker-community/ecosystem/commit/92a1a59d26e571dd13698125346c9144766c23b6))
* **hook-health:** stop a re-source relabeling lib_schema :relieved: ([#369](https://github.com/onlooker-community/ecosystem/issues/369)) ([ff2868f](https://github.com/onlooker-community/ecosystem/commit/ff2868f0f609ec29a1efcf665d873d0e5185ba82))
* **hook-health:** stop hooks/.. erasing the plugin name :label: ([#367](https://github.com/onlooker-community/ecosystem/issues/367)) ([90af8c1](https://github.com/onlooker-community/ecosystem/commit/90af8c19df9c3536695eaad585608a87a874947d))
* **hook-health:** stop reading a killed hook as a healthy one :mag: ([#343](https://github.com/onlooker-community/ecosystem/issues/343)) ([6dfaaaf](https://github.com/onlooker-community/ecosystem/commit/6dfaaafe82c91e47606631f0675bba42f30b4230))
* **hooks:** attribute nested sessions to their own id :straight_ruler: ([#252](https://github.com/onlooker-community/ecosystem/issues/252)) ([74b34ec](https://github.com/onlooker-community/ecosystem/commit/74b34ecdc038d1e90b7a236077601ea1b6ec9ee8))
* **hooks:** make the claude re-entrancy guard a rule, not a habit :repeat: ([#244](https://github.com/onlooker-community/ecosystem/issues/244)) ([e75fe74](https://github.com/onlooker-community/ecosystem/commit/e75fe74d4006b5adb4bdcdebbd3a397c49684a9c))
* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))
* **plugins:** one project-key lib, not thirteen :detective: ([#432](https://github.com/onlooker-community/ecosystem/issues/432)) ([598b670](https://github.com/onlooker-community/ecosystem/commit/598b670195bc6e717f3172bd06c240a70b39ee73))
* **plugins:** read config ints as ints in the user-scope five :shield: ([#422](https://github.com/onlooker-community/ecosystem/issues/422)) ([8689641](https://github.com/onlooker-community/ecosystem/commit/8689641c1d92fcaab67af25328104e0094fe5fd6))
* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))


### Performance Improvements

* **clock:** stop paying python3 to ask what time it is :zap: ([#239](https://github.com/onlooker-community/ecosystem/issues/239)) ([2be081c](https://github.com/onlooker-community/ecosystem/commit/2be081c36ac7dd907ca55ce49bba51764aeb4396))
* **counsel:** stop blocking SessionStart on a 90s LLM call :hourglass: ([#246](https://github.com/onlooker-community/ecosystem/issues/246)) ([ef55fd9](https://github.com/onlooker-community/ecosystem/commit/ef55fd944774987305547ca433d847acfc28d52c))
* **project-key:** try the fast hash tiers first :zap: ([#437](https://github.com/onlooker-community/ecosystem/issues/437)) ([9a5a3ab](https://github.com/onlooker-community/ecosystem/commit/9a5a3ab2eaeb2e00a4d16c50f39eb070ebf62e78))

## [0.10.2](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.10.1...counsel-v0.10.2) (2026-10-14)


### Bug Fixes

* **counsel:** map every shipped plugin to a signal class :telescope: ([#441](https://github.com/onlooker-community/ecosystem/issues/441)) ([1967ad1](https://github.com/onlooker-community/ecosystem/commit/1967ad109abfd5d06efa4a9a6cc31c594679d80f))

## [0.10.1](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.10.0...counsel-v0.10.1) (2026-10-13)


### Performance Improvements

* **project-key:** try the fast hash tiers first :zap: ([#437](https://github.com/onlooker-community/ecosystem/issues/437)) ([9a5a3ab](https://github.com/onlooker-community/ecosystem/commit/9a5a3ab2eaeb2e00a4d16c50f39eb070ebf62e78))

## [0.10.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.9.2...counsel-v0.10.0) (2026-10-12)


### Features

* **envelope:** attribute every event to a repository :world_map: ([#435](https://github.com/onlooker-community/ecosystem/issues/435)) ([ab3fe4d](https://github.com/onlooker-community/ecosystem/commit/ab3fe4d1fd2c6f11d1284a8515efed732ef2aafb))

## [0.9.2](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.9.1...counsel-v0.9.2) (2026-10-11)


### Bug Fixes

* **plugins:** one project-key lib, not thirteen :detective: ([#432](https://github.com/onlooker-community/ecosystem/issues/432)) ([598b670](https://github.com/onlooker-community/ecosystem/commit/598b670195bc6e717f3172bd06c240a70b39ee73))

## [0.9.1](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.9.0...counsel-v0.9.1) (2026-10-08)


### Bug Fixes

* **plugins:** read config ints as ints in the user-scope five :shield: ([#422](https://github.com/onlooker-community/ecosystem/issues/422)) ([8689641](https://github.com/onlooker-community/ecosystem/commit/8689641c1d92fcaab67af25328104e0094fe5fd6))

## [0.9.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.8.5...counsel-v0.9.0) (2026-10-04)


### Features

* **config:** add a validating integer accessor :shield: ([#415](https://github.com/onlooker-community/ecosystem/issues/415)) ([879969e](https://github.com/onlooker-community/ecosystem/commit/879969ecc01cf1e293135d52c77aab4985575221))

## [0.8.5](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.8.4...counsel-v0.8.5) (2026-09-22)


### Bug Fixes

* **hook-health:** stop a re-source relabeling lib_schema :relieved: ([#369](https://github.com/onlooker-community/ecosystem/issues/369)) ([ff2868f](https://github.com/onlooker-community/ecosystem/commit/ff2868f0f609ec29a1efcf665d873d0e5185ba82))

## [0.8.4](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.8.3...counsel-v0.8.4) (2026-09-21)


### Bug Fixes

* **hook-health:** stop hooks/.. erasing the plugin name :label: ([#367](https://github.com/onlooker-community/ecosystem/issues/367)) ([90af8c1](https://github.com/onlooker-community/ecosystem/commit/90af8c19df9c3536695eaad585608a87a874947d))

## [0.8.3](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.8.2...counsel-v0.8.3) (2026-09-19)


### Bug Fixes

* **hook-health:** see the runs that die without a trap :footprints: ([#341](https://github.com/onlooker-community/ecosystem/issues/341)) ([92a1a59](https://github.com/onlooker-community/ecosystem/commit/92a1a59d26e571dd13698125346c9144766c23b6))
* **hook-health:** stop reading a killed hook as a healthy one :mag: ([#343](https://github.com/onlooker-community/ecosystem/issues/343)) ([6dfaaaf](https://github.com/onlooker-community/ecosystem/commit/6dfaaafe82c91e47606631f0675bba42f30b4230))

## [0.8.2](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.8.1...counsel-v0.8.2) (2026-09-13)


### Bug Fixes

* **config:** resolve settings roots in the loader, not at call sites :compass: ([#327](https://github.com/onlooker-community/ecosystem/issues/327)) ([50c5687](https://github.com/onlooker-community/ecosystem/commit/50c56873299401296a6ba6436adba3d56477f331))

## [0.8.1](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.8.0...counsel-v0.8.1) (2026-09-10)


### Bug Fixes

* **ecosystem:** let each hook keep its own name in the health log :mag: ([#309](https://github.com/onlooker-community/ecosystem/issues/309)) ([de701bf](https://github.com/onlooker-community/ecosystem/commit/de701bf958134709d0884aef018619c685b227de))

## [0.8.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.7.0...counsel-v0.8.0) (2026-09-08)


### Features

* **ecosystem:** stamp the plugin version each session actually runs :mag: ([#305](https://github.com/onlooker-community/ecosystem/issues/305)) ([d58361d](https://github.com/onlooker-community/ecosystem/commit/d58361dbd22909d683087e1a0dde1d644cff6e42))

## [0.7.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.6.7...counsel-v0.7.0) (2026-09-07)


### Features

* **hook-health:** let a record say which vendored copy wrote it :fingerprint: ([#290](https://github.com/onlooker-community/ecosystem/issues/290)) ([37bdbe5](https://github.com/onlooker-community/ecosystem/commit/37bdbe55ec5a01ece82c34dfc8ee95a6c2eda64b))

## [0.6.7](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.6.6...counsel-v0.6.7) (2026-09-06)


### Bug Fixes

* **events:** emit through the newest ecosystem, not the first one listed :satellite: ([#276](https://github.com/onlooker-community/ecosystem/issues/276)) ([1b3541c](https://github.com/onlooker-community/ecosystem/commit/1b3541c8bbeaf9c00a992ee339e2a726fa9e087c))

## [0.6.6](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.6.5...counsel-v0.6.6) (2026-09-05)


### Bug Fixes

* **hooks:** attribute nested sessions to their own id :straight_ruler: ([#252](https://github.com/onlooker-community/ecosystem/issues/252)) ([74b34ec](https://github.com/onlooker-community/ecosystem/commit/74b34ecdc038d1e90b7a236077601ea1b6ec9ee8))

## [0.6.5](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.6.4...counsel-v0.6.5) (2026-09-03)


### Performance Improvements

* **counsel:** stop blocking SessionStart on a 90s LLM call :hourglass: ([#246](https://github.com/onlooker-community/ecosystem/issues/246)) ([ef55fd9](https://github.com/onlooker-community/ecosystem/commit/ef55fd944774987305547ca433d847acfc28d52c))

## [0.6.4](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.6.3...counsel-v0.6.4) (2026-09-03)


### Bug Fixes

* **hooks:** make the claude re-entrancy guard a rule, not a habit :repeat: ([#244](https://github.com/onlooker-community/ecosystem/issues/244)) ([e75fe74](https://github.com/onlooker-community/ecosystem/commit/e75fe74d4006b5adb4bdcdebbd3a397c49684a9c))

## [0.6.3](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.6.2...counsel-v0.6.3) (2026-09-03)


### Performance Improvements

* **clock:** stop paying python3 to ask what time it is :zap: ([#239](https://github.com/onlooker-community/ecosystem/issues/239)) ([2be081c](https://github.com/onlooker-community/ecosystem/commit/2be081c36ac7dd907ca55ce49bba51764aeb4396))

## [0.6.2](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.6.1...counsel-v0.6.2) (2026-09-03)


### Bug Fixes

* **config:** honor CLAUDE_CONFIG_DIR for user settings :mag: ([#237](https://github.com/onlooker-community/ecosystem/issues/237)) ([057a40d](https://github.com/onlooker-community/ecosystem/commit/057a40d65d221dadef9d6fda235c87e032375235))

## [0.6.1](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.6.0...counsel-v0.6.1) (2026-08-30)


### Bug Fixes

* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))

## [0.6.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.5.3...counsel-v0.6.0) (2026-08-29)


### Features

* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))

## [0.5.3](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.5.2...counsel-v0.5.3) (2026-08-29)


### Bug Fixes

* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))

## [0.5.2](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.5.1...counsel-v0.5.2) (2026-08-22)


### Bug Fixes

* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))

## [0.5.1](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.5.0...counsel-v0.5.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.5.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.4.0...counsel-v0.5.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.3.1...counsel-v0.4.0) (2026-06-24)


### Features

* **plugins:** persist structured JSON and emit onlooker.artifact.ready :outbox_tray: ([#103](https://github.com/onlooker-community/ecosystem/issues/103)) ([9b689a4](https://github.com/onlooker-community/ecosystem/commit/9b689a41aa4bdb481fef93b484e6446da731e8f1))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.3.0...counsel-v0.3.1) (2026-06-12)


### Bug Fixes

* **counsel:** drop unsupported --max-tokens flag from claude synthesis call :relieved: ([#79](https://github.com/onlooker-community/ecosystem/issues/79)) ([ade85ce](https://github.com/onlooker-community/ecosystem/commit/ade85cecb3243781f47e14fea4990ce31e69e8f4))
* **counsel:** stop pipefail from discarding all events on large logs :relieved: ([#78](https://github.com/onlooker-community/ecosystem/issues/78)) ([638347d](https://github.com/onlooker-community/ecosystem/commit/638347dec3b9df740b7a85c3e475fa2ffe5d054b))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.2.0...counsel-v0.3.0) (2026-06-11)


### Features

* **counsel:** add /counsel on-demand weekly-review command :rocket: ([#76](https://github.com/onlooker-community/ecosystem/issues/76)) ([8ce951c](https://github.com/onlooker-community/ecosystem/commit/8ce951cd5cb7b173f194f86c2960a31fb0d6889d))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/counsel-v0.1.0...counsel-v0.2.0) (2026-06-02)


### Features

* **counsel:** weekly observability synthesis and coaching brief :robot: ([#51](https://github.com/onlooker-community/ecosystem/issues/51)) ([6364586](https://github.com/onlooker-community/ecosystem/commit/63645863cf3a1d7bbf0353aacb9b71e4f977dd56))

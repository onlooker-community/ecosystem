# Changelog

## [0.47.3](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.47.2...ecosystem-v0.47.3) (2026-09-02)


### Performance Improvements

* **lineage:** stop re-parsing the same payload ten times :zap: ([#231](https://github.com/onlooker-community/ecosystem/issues/231)) ([036c43f](https://github.com/onlooker-community/ecosystem/commit/036c43fe1d475ae1a7f2b42d7ba058bc39084b79))

## [0.47.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.47.1...ecosystem-v0.47.2) (2026-09-01)


### Performance Improvements

* **emitter:** stop loading ajv on every event in production :zap: ([#229](https://github.com/onlooker-community/ecosystem/issues/229)) ([c166960](https://github.com/onlooker-community/ecosystem/commit/c1669607ed1d011855005101a6cb9054e597e444))

## [0.47.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.47.0...ecosystem-v0.47.1) (2026-09-01)


### Bug Fixes

* **lineage:** close two silent provenance gaps :bug: ([#227](https://github.com/onlooker-community/ecosystem/issues/227)) ([32bde03](https://github.com/onlooker-community/ecosystem/commit/32bde034bbb70d5f85120abceea2cfa337526d12))

## [0.47.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.46.0...ecosystem-v0.47.0) (2026-09-01)


### Features

* **lineage:** record the edits made through the shell :satellite: ([#225](https://github.com/onlooker-community/ecosystem/issues/225)) ([8c12231](https://github.com/onlooker-community/ecosystem/commit/8c12231f27d792a411a1933197b05302c910c28f))

## [0.46.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.45.3...ecosystem-v0.46.0) (2026-08-30)


### Features

* **storage:** bound the onlooker store and reclaim 255MB of block waste :broom: ([#223](https://github.com/onlooker-community/ecosystem/issues/223)) ([2dc3f53](https://github.com/onlooker-community/ecosystem/commit/2dc3f53f5c10ed4fd861e0d456a1db197819c277))

## [0.45.3](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.45.2...ecosystem-v0.45.3) (2026-08-30)


### Bug Fixes

* **memory-recall:** read the memory store Claude Code actually writes :open_file_folder: ([#220](https://github.com/onlooker-community/ecosystem/issues/220)) ([7dc0a83](https://github.com/onlooker-community/ecosystem/commit/7dc0a8325f51fe23abe4927796f857289cdce256))

## [0.45.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.45.1...ecosystem-v0.45.2) (2026-08-30)


### Bug Fixes

* **hook-health:** register before sourcing so spans are comparable :straight_ruler: ([#217](https://github.com/onlooker-community/ecosystem/issues/217)) ([20e620a](https://github.com/onlooker-community/ecosystem/commit/20e620a0aacf018993130e05749e8b4e6199726c))

## [0.45.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.45.0...ecosystem-v0.45.1) (2026-08-30)


### Bug Fixes

* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))

## [0.45.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.44.2...ecosystem-v0.45.0) (2026-08-29)


### Features

* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))

## [0.44.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.44.1...ecosystem-v0.44.2) (2026-08-29)


### Bug Fixes

* **gates:** emit the documented permissionDecision deny shape :shield: ([#211](https://github.com/onlooker-community/ecosystem/issues/211)) ([c68e758](https://github.com/onlooker-community/ecosystem/commit/c68e758c48fbfe1359435ef7143724e3686968e2))

## [0.44.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.44.0...ecosystem-v0.44.1) (2026-08-29)


### Bug Fixes

* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))

## [0.44.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.43.7...ecosystem-v0.44.0) (2026-08-23)


### Features

* **librarian:** let lessons status close the judge walk :abacus: ([#205](https://github.com/onlooker-community/ecosystem/issues/205)) ([8da1cd7](https://github.com/onlooker-community/ecosystem/commit/8da1cd72a7e564aae44750efaa1e59f1ecd59641))

## [0.43.7](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.43.6...ecosystem-v0.43.7) (2026-08-23)


### Bug Fixes

* **cartographer:** drop a typeless finding instead of hashing it as "unknown" :broom: ([#203](https://github.com/onlooker-community/ecosystem/issues/203)) ([a949d5d](https://github.com/onlooker-community/ecosystem/commit/a949d5d43f3ae3515ac6278b35d1be5cc468cb0e))

## [0.43.6](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.43.5...ecosystem-v0.43.6) (2026-08-22)


### Bug Fixes

* **events:** drop safe_emit's hand-built envelope fallback :broom: ([#202](https://github.com/onlooker-community/ecosystem/issues/202)) ([bad684a](https://github.com/onlooker-community/ecosystem/commit/bad684a4f7c535d72f91ed2b1d4928a4dd9a10e8))
* **inspector:** canonicalize the file and repo root the same way :mag: ([0f850e9](https://github.com/onlooker-community/ecosystem/commit/0f850e92d7e620e4d7e06f512ef81efe4255f316))

## [0.43.5](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.43.4...ecosystem-v0.43.5) (2026-08-22)


### Bug Fixes

* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))
* **librarian:** key the declined-ledger guard on the proposal, not the artifact :bug: ([#199](https://github.com/onlooker-community/ecosystem/issues/199)) ([47a195d](https://github.com/onlooker-community/ecosystem/commit/47a195da98a3a565018c35e9e5c6dde2405520de))

## [0.43.4](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.43.3...ecosystem-v0.43.4) (2026-08-22)


### Bug Fixes

* **events:** route prompt_rule emission through the canonical emitter :relieved: ([#196](https://github.com/onlooker-community/ecosystem/issues/196)) ([c233bfa](https://github.com/onlooker-community/ecosystem/commit/c233bfa466cf400e767f4673e0143081618314a7))

## [0.43.3](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.43.2...ecosystem-v0.43.3) (2026-08-22)


### Bug Fixes

* **ci:** fence bd-managed blocks against lint churn :relieved: ([#194](https://github.com/onlooker-community/ecosystem/issues/194)) ([e09fcb6](https://github.com/onlooker-community/ecosystem/commit/e09fcb6836645999feb831a7494236d4a54ed318))

## [0.43.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.43.1...ecosystem-v0.43.2) (2026-08-21)


### Bug Fixes

* **ci:** shellcheck every tracked script, not a stale list :broom: ([#190](https://github.com/onlooker-community/ecosystem/issues/190)) ([841a37c](https://github.com/onlooker-community/ecosystem/commit/841a37cfa2c8a0eb2ff540f67b4b5a10eb4ed161))

## [0.43.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.43.0...ecosystem-v0.43.1) (2026-08-20)


### Bug Fixes

* **release:** upgrade npm so trusted publishing runs :relieved: ([#188](https://github.com/onlooker-community/ecosystem/issues/188)) ([caf6dfd](https://github.com/onlooker-community/ecosystem/commit/caf6dfddc3d906708538c258755d9bd8297970c1))

## [0.43.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.42.2...ecosystem-v0.43.0) (2026-08-19)


### Features

* **cartographer:** announce a finding when its drift is gone :wave: ([#186](https://github.com/onlooker-community/ecosystem/issues/186)) ([f2b57f6](https://github.com/onlooker-community/ecosystem/commit/f2b57f67b3e09f7ec624bce0bb4a306c4e20df8b))

## [0.42.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.42.1...ecosystem-v0.42.2) (2026-08-19)


### Bug Fixes

* **release:** publish with provenance so npm stops refusing us :unlock: ([#184](https://github.com/onlooker-community/ecosystem/issues/184)) ([0921118](https://github.com/onlooker-community/ecosystem/commit/0921118401a4c165ba07471a5d573dbe21a35119))

## [0.42.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.42.0...ecosystem-v0.42.1) (2026-08-19)


### Bug Fixes

* **cartographer:** refuse a typeless finding out loud :loudspeaker: ([#182](https://github.com/onlooker-community/ecosystem/issues/182)) ([35ee0af](https://github.com/onlooker-community/ecosystem/commit/35ee0af055fd360a70a77d6ef036bbeb91dcc945))

## [0.42.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.41.3...ecosystem-v0.42.0) (2026-08-18)


### Features

* **cartographer:** narrow an audit by finding type or subtree :mag: ([#177](https://github.com/onlooker-community/ecosystem/issues/177)) ([94764df](https://github.com/onlooker-community/ecosystem/commit/94764dfc8386521a06c8234bc506cb51a667588d))


### Bug Fixes

* **librarian:** put budget skips on the bus at last :satellite: ([#180](https://github.com/onlooker-community/ecosystem/issues/180)) ([bc91749](https://github.com/onlooker-community/ecosystem/commit/bc917495dab053cba825ea28ccdd1993fdacb3e9))
* **librarian:** stop stage 5 from holding a session open :hourglass: ([#178](https://github.com/onlooker-community/ecosystem/issues/178)) ([4f12a1e](https://github.com/onlooker-community/ecosystem/commit/4f12a1ee25300e0dc372542814e0922df5dbd335))

## [0.41.3](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.41.2...ecosystem-v0.41.3) (2026-08-17)


### Bug Fixes

* **cartographer:** make the audit read the settings you gave it :gear: ([#174](https://github.com/onlooker-community/ecosystem/issues/174)) ([dc57731](https://github.com/onlooker-community/ecosystem/commit/dc5773165fe561f77e87101ed1fbe6e13bb34c34))
* **release:** drop git config --global and switch to GITHUB_TOKEN with id-token:write ([#175](https://github.com/onlooker-community/ecosystem/issues/175)) ([b70668b](https://github.com/onlooker-community/ecosystem/commit/b70668b90cff7d33e012363ede673b0c3e9da29f))

## [0.41.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.41.1...ecosystem-v0.41.2) (2026-08-17)


### Bug Fixes

* **cartographer:** let a finding you fixed finally go away :wastebasket: ([#172](https://github.com/onlooker-community/ecosystem/issues/172)) ([c8fdcf4](https://github.com/onlooker-community/ecosystem/commit/c8fdcf40b711b68ee5d90e2c4b6408ea38926900))

## [0.41.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.41.0...ecosystem-v0.41.1) (2026-08-17)


### Bug Fixes

* **cartographer:** put its events on the bus for the first time :mega: ([#170](https://github.com/onlooker-community/ecosystem/issues/170)) ([91be8d2](https://github.com/onlooker-community/ecosystem/commit/91be8d2c9f171006db12842f3e582d001f9d4e27))

## [0.41.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.8...ecosystem-v0.41.0) (2026-08-16)


### Features

* **cartographer:** detect what no instruction file mentions :eyes: ([#168](https://github.com/onlooker-community/ecosystem/issues/168)) ([31efb7b](https://github.com/onlooker-community/ecosystem/commit/31efb7b035665d5a49a37c1e1af21f519850f7bd))

## [0.40.8](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.7...ecosystem-v0.40.8) (2026-08-16)


### Bug Fixes

* **tribunal:** let every blocking arm name the floor it tripped over :label: ([#166](https://github.com/onlooker-community/ecosystem/issues/166)) ([1819b5f](https://github.com/onlooker-community/ecosystem/commit/1819b5f7ad0348584bcb0e72e28c9af153ba3a4d))

## [0.40.7](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.6...ecosystem-v0.40.7) (2026-08-16)


### Bug Fixes

* **tribunal:** stop a low criterion from hiding why the panel failed :arrows_counterclockwise: ([#164](https://github.com/onlooker-community/ecosystem/issues/164)) ([a3ec128](https://github.com/onlooker-community/ecosystem/commit/a3ec128f1e2e723e02396580b9ffbcff26f0787f))

## [0.40.6](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.5...ecosystem-v0.40.6) (2026-08-16)


### Bug Fixes

* **tribunal:** a floor you cannot read is a floor you cannot clear :lock: ([#162](https://github.com/onlooker-community/ecosystem/issues/162)) ([4ff2ec0](https://github.com/onlooker-community/ecosystem/commit/4ff2ec0f772af51ad4b5ea631ae2d3c68d229499))

## [0.40.5](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.4...ecosystem-v0.40.5) (2026-08-16)


### Bug Fixes

* **tribunal:** refuse a score that is not on the scale it claims :straight_ruler: ([#160](https://github.com/onlooker-community/ecosystem/issues/160)) ([bab2855](https://github.com/onlooker-community/ecosystem/commit/bab28558a68402c1dd67623f469467fd99302ba6))

## [0.40.4](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.3...ecosystem-v0.40.4) (2026-08-16)


### Bug Fixes

* **tribunal:** stop a verdict nobody scored from voting to approve :no_entry: ([#158](https://github.com/onlooker-community/ecosystem/issues/158)) ([1d6c2dc](https://github.com/onlooker-community/ecosystem/commit/1d6c2dc9c8f5833891732dc7e6637c496ba81f6f))

## [0.40.3](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.2...ecosystem-v0.40.3) (2026-08-15)


### Bug Fixes

* **librarian:** make proposals the sole dedup source, and say so :broom: ([#156](https://github.com/onlooker-community/ecosystem/issues/156)) ([729d9ea](https://github.com/onlooker-community/ecosystem/commit/729d9ea3e328c2734712cfc5adf556c6798334aa))

## [0.40.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.1...ecosystem-v0.40.2) (2026-08-15)


### Bug Fixes

* **tribunal:** drop scoreless verdicts instead of averaging them in :bug: ([#154](https://github.com/onlooker-community/ecosystem/issues/154)) ([f546757](https://github.com/onlooker-community/ecosystem/commit/f5467574f08094b0369f0bd699983cb41ded2cc3))

## [0.40.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.40.0...ecosystem-v0.40.1) (2026-08-15)


### Bug Fixes

* **tribunal:** close two ways a criterion floor could still be escaped :relieved: ([#152](https://github.com/onlooker-community/ecosystem/issues/152)) ([5b2ddee](https://github.com/onlooker-community/ecosystem/commit/5b2ddee8a787ba0f3e8656a6522b12f348f74859))

## [0.40.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.39.1...ecosystem-v0.40.0) (2026-08-15)


### Features

* **tribunal,librarian:** make rubric weights and min_pass floors real :straight_ruler: ([#150](https://github.com/onlooker-community/ecosystem/issues/150)) ([f8f8e28](https://github.com/onlooker-community/ecosystem/commit/f8f8e28b60f6d13d5a2a54e26ca284137b77f99a))

## [0.39.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.39.0...ecosystem-v0.39.1) (2026-08-14)


### Bug Fixes

* **librarian:** close four follow-up defects from the promotion epic :broom: ([#148](https://github.com/onlooker-community/ecosystem/issues/148)) ([895df74](https://github.com/onlooker-community/ecosystem/commit/895df7430fa8ba75976d38964d061c21bff785d3))

## [0.39.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.38.0...ecosystem-v0.39.0) (2026-08-13)


### Features

* **librarian:** land judged lessons in the approved pool :package: ([#146](https://github.com/onlooker-community/ecosystem/issues/146)) ([f7adc72](https://github.com/onlooker-community/ecosystem/commit/f7adc7263a985d4cb7695b46d6f9dbab77dce587))

## [0.38.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.37.0...ecosystem-v0.38.0) (2026-08-13)


### Features

* **librarian:** derive an author identity that cannot be linked across scopes :closed_lock_with_key: ([#144](https://github.com/onlooker-community/ecosystem/issues/144)) ([29b3042](https://github.com/onlooker-community/ecosystem/commit/29b3042ef6cd6e7582206cfea6fcf37ebe661021))

## [0.37.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.36.0...ecosystem-v0.37.0) (2026-08-12)


### Features

* **librarian:** judge lessons before they leave the machine :balance_scale: ([#142](https://github.com/onlooker-community/ecosystem/issues/142)) ([a877527](https://github.com/onlooker-community/ecosystem/commit/a87752714961613b6b2bb768239c666f78d950f8))

## [0.36.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.35.0...ecosystem-v0.36.0) (2026-08-11)


### Features

* **librarian:** let a human take back a lesson confirmation :leftwards_arrow_with_hook: ([#139](https://github.com/onlooker-community/ecosystem/issues/139)) ([a4c4ac8](https://github.com/onlooker-community/ecosystem/commit/a4c4ac8ed5b79f5596f4e22abd1d23a8b0d3e834))

## [0.35.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.34.1...ecosystem-v0.35.0) (2026-08-11)


### Features

* **librarian:** let a human decide what leaves the machine :raised_hand: ([#137](https://github.com/onlooker-community/ecosystem/issues/137)) ([16d7673](https://github.com/onlooker-community/ecosystem/commit/16d76734833aee9c8818f84c1c1f704be4cdfc33))

## [0.34.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.34.0...ecosystem-v0.34.1) (2026-08-10)


### Bug Fixes

* make the local bats suite tell the truth :mag: ([#135](https://github.com/onlooker-community/ecosystem/issues/135)) ([f0763e0](https://github.com/onlooker-community/ecosystem/commit/f0763e09f3caf2d39c89f28befd12567af0af845))

## [0.34.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.33.1...ecosystem-v0.34.0) (2026-08-09)


### Features

* **librarian:** transform artifacts into shareable lesson candidates :microscope: ([#132](https://github.com/onlooker-community/ecosystem/issues/132)) ([48adbc7](https://github.com/onlooker-community/ecosystem/commit/48adbc7ec572b96b47f1be5f92810088c98702c6))

## [0.33.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.33.0...ecosystem-v0.33.1) (2026-08-02)


### Bug Fixes

* restore config convenience functions & refactor execution plugins to shared loader ([#128](https://github.com/onlooker-community/ecosystem/issues/128)) ([4b3660c](https://github.com/onlooker-community/ecosystem/commit/4b3660c5a8b234187ec1e71c37b63e6a3d305c98))

## [0.33.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.32.2...ecosystem-v0.33.0) (2026-08-02)


### Features

* **config:** add shared config loader supporting all five settings layers :sparkles: ([#123](https://github.com/onlooker-community/ecosystem/issues/123)) ([c048b76](https://github.com/onlooker-community/ecosystem/commit/c048b76bee2b39abeb7f1af77181191dd48f9cf5))


### Bug Fixes

* **hooks:** prevent SessionEnd timeouts causing breadcrumb accumulation ([#121](https://github.com/onlooker-community/ecosystem/issues/121)) ([3c7a409](https://github.com/onlooker-community/ecosystem/commit/3c7a40937aa3ea8c1db85dd0bb3fcc22589bbb49))

## [0.32.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.32.1...ecosystem-v0.32.2) (2026-08-02)


### Bug Fixes

* librarian + bursar + governor improvements ([#119](https://github.com/onlooker-community/ecosystem/issues/119)) ([d7cdab5](https://github.com/onlooker-community/ecosystem/commit/d7cdab528ea5181ea35da68fbc5ad2e5b064abea))

## [0.32.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.32.0...ecosystem-v0.32.1) (2026-08-02)


### Bug Fixes

* librarian conflict detection + bursar rollup lock timeout ([#117](https://github.com/onlooker-community/ecosystem/issues/117)) ([16180a2](https://github.com/onlooker-community/ecosystem/commit/16180a210a6f0561c09b77a2b102849f63f1e730))

## [0.32.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.31.2...ecosystem-v0.32.0) (2026-08-02)


### Features

* add configuration and hooks for agent spawn tracking ([3ef4590](https://github.com/onlooker-community/ecosystem/commit/3ef459006bbbda246604bdd1ffaf9af0a59f9740))
* add settings.json for plugin configuration ([67fbdfe](https://github.com/onlooker-community/ecosystem/commit/67fbdfe37f067a45801e7d0355c4a533b687f6b2))
* **archivist:** introduce structured session memory plugin :rocket: ([378fff3](https://github.com/onlooker-community/ecosystem/commit/378fff3c14b40644af45b1a2335992e7b0428160))
* **assayer:** introduce claim-verification plugin ([#70](https://github.com/onlooker-community/ecosystem/issues/70)) ([1d0500b](https://github.com/onlooker-community/ecosystem/commit/1d0500b64f8cd670d1cfa1ac070182d72696bdfd))
* **bursar:** introduce multi-session budget rollup plugin ([#81](https://github.com/onlooker-community/ecosystem/issues/81)) ([b11e687](https://github.com/onlooker-community/ecosystem/commit/b11e687744bab70a94025c46c4aaa58fb7ea97f4))
* **cartographer:** add proactive instruction-file audit plugin :mag: ([#35](https://github.com/onlooker-community/ecosystem/issues/35)) ([387d00a](https://github.com/onlooker-community/ecosystem/commit/387d00ad04da5aae91048254ad0526bb674ed498))
* **compass:** pre-write intent clarity gate plugin :compass: ([#47](https://github.com/onlooker-community/ecosystem/issues/47)) ([144c2ef](https://github.com/onlooker-community/ecosystem/commit/144c2ef44d28bab3dcec14a9eace7ec76470d090))
* **counsel:** add /counsel on-demand weekly-review command :rocket: ([#76](https://github.com/onlooker-community/ecosystem/issues/76)) ([8ce951c](https://github.com/onlooker-community/ecosystem/commit/8ce951cd5cb7b173f194f86c2960a31fb0d6889d))
* **counsel:** weekly observability synthesis and coaching brief :robot: ([#51](https://github.com/onlooker-community/ecosystem/issues/51)) ([6364586](https://github.com/onlooker-community/ecosystem/commit/63645863cf3a1d7bbf0353aacb9b71e4f977dd56))
* **coverage:** report node + bash coverage on every PR :sparkles: ([cb5d122](https://github.com/onlooker-community/ecosystem/commit/cb5d1221ad20e6257d66b507897dae14549a870f))
* **curator:** introduce plugin with cheap-tier checks :microscope: ([#57](https://github.com/onlooker-community/ecosystem/issues/57)) ([7f9fa18](https://github.com/onlooker-community/ecosystem/commit/7f9fa18bbde29c8b5bd1eaad185bd4c5595a3762))
* **echo:** add prompt regression detection plugin ([#32](https://github.com/onlooker-community/ecosystem/issues/32)) ([65274d4](https://github.com/onlooker-community/ecosystem/commit/65274d4d8326950d6c998ca292fed13b1b8c493b))
* **ecosystem:** emit memory.recalled at SessionStart :link: ([#62](https://github.com/onlooker-community/ecosystem/issues/62)) ([d5876f9](https://github.com/onlooker-community/ecosystem/commit/d5876f9f819165cc07d691d733662b549863b7f5))
* **governor:** resource governance and budget enforcement plugin :rocket: ([#43](https://github.com/onlooker-community/ecosystem/issues/43)) ([04e6d70](https://github.com/onlooker-community/ecosystem/commit/04e6d7051f27db752bb121d389d65b4d8ade04ad))
* **historian:** introduce SessionEnd indexing :spiral_notepad: ([#59](https://github.com/onlooker-community/ecosystem/issues/59)) ([dd6c7f6](https://github.com/onlooker-community/ecosystem/commit/dd6c7f6ea872437cab6b16de50838dfc72750c7b))
* **historian:** retrieval pipeline + ollama embedder :telescope: ([#61](https://github.com/onlooker-community/ecosystem/issues/61)) ([7eae752](https://github.com/onlooker-community/ecosystem/commit/7eae752a288c4678ab093042469f2e65d428f0d9))
* **hooks:** add PreCompact and PostCompact context compaction trackers ([#15](https://github.com/onlooker-community/ecosystem/issues/15)) ([1ec5632](https://github.com/onlooker-community/ecosystem/commit/1ec5632404676ed8b35d324b79ad71a2e9093505))
* **hooks:** add SessionStart and SessionEnd session trackers ([#10](https://github.com/onlooker-community/ecosystem/issues/10)) ([a48d680](https://github.com/onlooker-community/ecosystem/commit/a48d680dd24c98e79ef1c0401b07483ecebf9e8b))
* **hooks:** add TaskCreated and TaskCompleted task lifecycle trackers ([#21](https://github.com/onlooker-community/ecosystem/issues/21)) ([986ffa8](https://github.com/onlooker-community/ecosystem/commit/986ffa84bdd857a464ca0d556671628190ed27bc))
* **hooks:** add UserPromptSubmit turn and session duration trackers ([#12](https://github.com/onlooker-community/ecosystem/issues/12)) ([cbb7657](https://github.com/onlooker-community/ecosystem/commit/cbb7657979ed144efce506e6b487e037679b9462))
* **hooks:** add WorktreeCreate and WorktreeRemove lifecycle trackers ([#24](https://github.com/onlooker-community/ecosystem/issues/24)) ([ff55e39](https://github.com/onlooker-community/ecosystem/commit/ff55e397a0c0adc3e76f66aba12c6b237149ad17))
* **hooks:** emit canonical schema events for tool history :sparkles: ([1e49a24](https://github.com/onlooker-community/ecosystem/commit/1e49a24bfb930942fa477b594395ef352618f574))
* **hooks:** enrich tool.file.read with read chunking observability ([#25](https://github.com/onlooker-community/ecosystem/issues/25)) ([8eb23c8](https://github.com/onlooker-community/ecosystem/commit/8eb23c8f4f03dfbeb701a30de1fa50c1c8ee48ac))
* **hooks:** track skill usage via skill.invoked events ([23fff0f](https://github.com/onlooker-community/ecosystem/commit/23fff0f0bfad8ab91788d8c45a0457d099d2e870))
* **hooks:** track tool call sequence on every PreToolUse :sparkles: ([0ad9546](https://github.com/onlooker-community/ecosystem/commit/0ad95465cc22a237e26115a67814a6e7b2951b1d))
* **inspector:** ship the per-edit lint/typecheck plugin ([#88](https://github.com/onlooker-community/ecosystem/issues/88)) ([2018243](https://github.com/onlooker-community/ecosystem/commit/201824384abd6a4fc5f4395266924aa413a2ffd1))
* **librarian:** /librarian review skill closes promotion loop :tada: ([#68](https://github.com/onlooker-community/ecosystem/issues/68)) ([8f3e3db](https://github.com/onlooker-community/ecosystem/commit/8f3e3dbdf6f08dceb0cf61d46281936a4f9954de))
* **librarian:** implement conflict detection for memory promotion scanning ([#115](https://github.com/onlooker-community/ecosystem/issues/115)) ([8699577](https://github.com/onlooker-community/ecosystem/commit/86995773cb44127d915b5aea53aed66c771d8bfb))
* **librarian:** land plugin end-to-end with memory layer designs :seedling: ([#55](https://github.com/onlooker-community/ecosystem/issues/55)) ([d4821ef](https://github.com/onlooker-community/ecosystem/commit/d4821efabfeb587e460e898d7db8f92fcc3f2c61))
* **lineage:** introduce per-change provenance plugin ([#83](https://github.com/onlooker-community/ecosystem/issues/83)) ([86b00d3](https://github.com/onlooker-community/ecosystem/commit/86b00d3d7393e2b63c5b04d60692fc89f202bf6c))
* **lint:** add marketplace cross-reference linter :nail_care: ([0f48817](https://github.com/onlooker-community/ecosystem/commit/0f488170326659ef1d0b8bd7ae4d207c78a43694))
* **lint:** add plugin manifest validator :nail_care: ([e12615f](https://github.com/onlooker-community/ecosystem/commit/e12615ff99d43caf59d5e215d882c0acb3352c01))
* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))
* **plugins:** persist structured JSON and emit onlooker.artifact.ready :outbox_tray: ([#103](https://github.com/onlooker-community/ecosystem/issues/103)) ([9b689a4](https://github.com/onlooker-community/ecosystem/commit/9b689a41aa4bdb481fef93b484e6446da731e8f1))
* **prompt-rules:** deterministic regex-triggered guidance injection :relieved: ([#28](https://github.com/onlooker-community/ecosystem/issues/28)) ([662c811](https://github.com/onlooker-community/ecosystem/commit/662c8119657cebc350900f859c43dbaca97d6703))
* **scribe:** intent documentation from agent activity :pencil2: ([#50](https://github.com/onlooker-community/ecosystem/issues/50)) ([f0a95d1](https://github.com/onlooker-community/ecosystem/commit/f0a95d1058e36d1bb5f0f645964d9e88e8f98b66))
* **tribunal:** add multi-agent code review plugin :sparkles: ([#30](https://github.com/onlooker-community/ecosystem/issues/30)) ([893f24a](https://github.com/onlooker-community/ecosystem/commit/893f24a8876fdd6ccb5c7dcf2636a7c902e88949))
* **warden:** untrusted-content gate enforcing the Agents Rule of Two :shield: ([#53](https://github.com/onlooker-community/ecosystem/issues/53)) ([210aa51](https://github.com/onlooker-community/ecosystem/commit/210aa51bff66226a0eec1f17292a2af4ea4ef56a))


### Bug Fixes

* **cartographer:** correct typo in release-please bump-patch key :face_with_spiral_eyes: ([#91](https://github.com/onlooker-community/ecosystem/issues/91)) ([dfab160](https://github.com/onlooker-community/ecosystem/commit/dfab1602afda2b6255a72b0975ebab9289d75b8e))
* **ci:** apply release-please extra-files for Claude plugin manifests ([#17](https://github.com/onlooker-community/ecosystem/issues/17)) ([da9913c](https://github.com/onlooker-community/ecosystem/commit/da9913ca4f7497280edc34f8c64baa903c1e6754))
* **ci:** checkout release tag before npm publish :relieved: ([bc7bbdc](https://github.com/onlooker-community/ecosystem/commit/bc7bbdc7a886a55ba8f04fe09bfa60043648c766))
* **ci:** grant id-token write for npm provenance on publish ([c78c9f0](https://github.com/onlooker-community/ecosystem/commit/c78c9f054c1d48ca8a83d0d26b76ce991fffe51b))
* **ci:** parse release-please paths_released JSON for npm publish ([749e1a0](https://github.com/onlooker-community/ecosystem/commit/749e1a02b563f37f81a8da21fc3f6e10e179314a))
* **ci:** stop upgrading npm globally before publish ([a7c7a0e](https://github.com/onlooker-community/ecosystem/commit/a7c7a0e1f25aee1bbb75bdd2af130dbc276480a6))
* **ci:** use HTTPS repository URL for npm provenance ([a7e8927](https://github.com/onlooker-community/ecosystem/commit/a7e89275c5a025a8afee009853265b717091f6ca))
* **ci:** use paths_released to gate npm publish :rage: ([#37](https://github.com/onlooker-community/ecosystem/issues/37)) ([c62b17f](https://github.com/onlooker-community/ecosystem/commit/c62b17f7e1352cfe260a23c8f48be30f72edbbed))
* **compass:** resolve MultiEdit file path from the top-level field ([#85](https://github.com/onlooker-community/ecosystem/issues/85)) ([468abaa](https://github.com/onlooker-community/ecosystem/commit/468abaaad4bef59fe4308bd8887dfcf6d633921a))
* **counsel:** drop unsupported --max-tokens flag from claude synthesis call :relieved: ([#79](https://github.com/onlooker-community/ecosystem/issues/79)) ([ade85ce](https://github.com/onlooker-community/ecosystem/commit/ade85cecb3243781f47e14fea4990ce31e69e8f4))
* **counsel:** stop pipefail from discarding all events on large logs :relieved: ([#78](https://github.com/onlooker-community/ecosystem/issues/78)) ([638347d](https://github.com/onlooker-community/ecosystem/commit/638347dec3b9df740b7a85c3e475fa2ffe5d054b))
* **emitter:** make emission dependency-free and fail-open :relieved: ([#99](https://github.com/onlooker-community/ecosystem/issues/99)) ([0dda7f8](https://github.com/onlooker-community/ecosystem/commit/0dda7f803ed2dfa28561bd8d9e4193b2b18e5bbf))
* **historian:** export CLAUDE_PLUGIN_ROOT so config loads correctly :bug: ([#112](https://github.com/onlooker-community/ecosystem/issues/112)) ([f24b0b4](https://github.com/onlooker-community/ecosystem/commit/f24b0b4375c64385fefd329cd07d8874785002e9))
* **historian:** repair CI broken by embedder check + document PR workflow :nail_care: ([#106](https://github.com/onlooker-community/ecosystem/issues/106)) ([02062a2](https://github.com/onlooker-community/ecosystem/commit/02062a21163e084705dae9cf421719b6e5a7b306))
* **hooks:** replace flock with portable mkdir mutex :bug: ([3dffa6f](https://github.com/onlooker-community/ecosystem/commit/3dffa6f5e43ef9f3c117f2406ddd03ce485df1cd))
* **package:** update repository URL format in package.json ([591ce9f](https://github.com/onlooker-community/ecosystem/commit/591ce9f54dd605ec04ceb77b9dcca40b3e08621e))
* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))
* **release:** sync marketplace.json out-of-band :relieved: ([0d2a0a3](https://github.com/onlooker-community/ecosystem/commit/0d2a0a38c0c4ee0e400b9a143a4be7904ea3f70a))
* **scribe:** mark hook scripts executable :relieved: ([#64](https://github.com/onlooker-community/ecosystem/issues/64)) ([05603e5](https://github.com/onlooker-community/ecosystem/commit/05603e56895c009c1435d1712592adbbc4c15e61))
* **tribunal:** persist all artifacts on every iteration including retries :relieved: ([#41](https://github.com/onlooker-community/ecosystem/issues/41)) ([1636105](https://github.com/onlooker-community/ecosystem/commit/163610535a4ce0fa73c8fb82dc5c6296d2d1065a))
* vendor portable-lock.sh into cartographer and governor ([#73](https://github.com/onlooker-community/ecosystem/issues/73)) ([ab2c354](https://github.com/onlooker-community/ecosystem/commit/ab2c354b131c26cc642ebb51e84a043dc43cbaa1))


### Performance Improvements

* **bursar:** collapse process forks in SessionEnd hot path :relieved: ([#101](https://github.com/onlooker-community/ecosystem/issues/101)) ([7a426fe](https://github.com/onlooker-community/ecosystem/commit/7a426fe359785eca35ea1ad61523b05fda79e0da))
* **historian:** fix O(n²) chunk loop and embedder false-positive :relieved: ([4ef130a](https://github.com/onlooker-community/ecosystem/commit/4ef130a4c01ec378da5b4d8baeeb7b4fb6059272))

## [0.31.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.31.1...ecosystem-v0.31.2) (2026-08-01)


### Bug Fixes

* **historian:** export CLAUDE_PLUGIN_ROOT so config loads correctly :bug: ([#112](https://github.com/onlooker-community/ecosystem/issues/112)) ([f24b0b4](https://github.com/onlooker-community/ecosystem/commit/f24b0b4375c64385fefd329cd07d8874785002e9))

## [0.31.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.31.0...ecosystem-v0.31.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.31.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.30.1...ecosystem-v0.31.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

## [0.30.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.30.0...ecosystem-v0.30.1) (2026-06-28)


### Bug Fixes

* **historian:** repair CI broken by embedder check + document PR workflow :nail_care: ([#106](https://github.com/onlooker-community/ecosystem/issues/106)) ([02062a2](https://github.com/onlooker-community/ecosystem/commit/02062a21163e084705dae9cf421719b6e5a7b306))


### Performance Improvements

* **historian:** fix O(n²) chunk loop and embedder false-positive :relieved: ([4ef130a](https://github.com/onlooker-community/ecosystem/commit/4ef130a4c01ec378da5b4d8baeeb7b4fb6059272))

## [0.30.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.29.3...ecosystem-v0.30.0) (2026-06-24)


### Features

* **plugins:** persist structured JSON and emit onlooker.artifact.ready :outbox_tray: ([#103](https://github.com/onlooker-community/ecosystem/issues/103)) ([9b689a4](https://github.com/onlooker-community/ecosystem/commit/9b689a41aa4bdb481fef93b484e6446da731e8f1))

## [0.29.3](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.29.2...ecosystem-v0.29.3) (2026-06-24)


### Performance Improvements

* **bursar:** collapse process forks in SessionEnd hot path :relieved: ([#101](https://github.com/onlooker-community/ecosystem/issues/101)) ([7a426fe](https://github.com/onlooker-community/ecosystem/commit/7a426fe359785eca35ea1ad61523b05fda79e0da))

## [0.29.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.29.1...ecosystem-v0.29.2) (2026-06-21)


### Bug Fixes

* **emitter:** make emission dependency-free and fail-open :relieved: ([#99](https://github.com/onlooker-community/ecosystem/issues/99)) ([0dda7f8](https://github.com/onlooker-community/ecosystem/commit/0dda7f803ed2dfa28561bd8d9e4193b2b18e5bbf))

## [0.29.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.29.0...ecosystem-v0.29.1) (2026-06-15)


### Bug Fixes

* **cartographer:** correct typo in release-please bump-patch key :face_with_spiral_eyes: ([#91](https://github.com/onlooker-community/ecosystem/issues/91)) ([dfab160](https://github.com/onlooker-community/ecosystem/commit/dfab1602afda2b6255a72b0975ebab9289d75b8e))

## [0.29.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.28.1...ecosystem-v0.29.0) (2026-06-15)


### Features

* **inspector:** ship the per-edit lint/typecheck plugin ([#88](https://github.com/onlooker-community/ecosystem/issues/88)) ([2018243](https://github.com/onlooker-community/ecosystem/commit/201824384abd6a4fc5f4395266924aa413a2ffd1))

## [0.28.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.28.0...ecosystem-v0.28.1) (2026-06-12)


### Bug Fixes

* **compass:** resolve MultiEdit file path from the top-level field ([#85](https://github.com/onlooker-community/ecosystem/issues/85)) ([468abaa](https://github.com/onlooker-community/ecosystem/commit/468abaaad4bef59fe4308bd8887dfcf6d633921a))

## [0.28.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.27.0...ecosystem-v0.28.0) (2026-06-12)


### Features

* **lineage:** introduce per-change provenance plugin ([#83](https://github.com/onlooker-community/ecosystem/issues/83)) ([86b00d3](https://github.com/onlooker-community/ecosystem/commit/86b00d3d7393e2b63c5b04d60692fc89f202bf6c))

## [0.27.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.26.1...ecosystem-v0.27.0) (2026-06-12)


### Features

* **bursar:** introduce multi-session budget rollup plugin ([#81](https://github.com/onlooker-community/ecosystem/issues/81)) ([b11e687](https://github.com/onlooker-community/ecosystem/commit/b11e687744bab70a94025c46c4aaa58fb7ea97f4))

## [0.26.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.26.0...ecosystem-v0.26.1) (2026-06-12)


### Bug Fixes

* **counsel:** drop unsupported --max-tokens flag from claude synthesis call :relieved: ([#79](https://github.com/onlooker-community/ecosystem/issues/79)) ([ade85ce](https://github.com/onlooker-community/ecosystem/commit/ade85cecb3243781f47e14fea4990ce31e69e8f4))
* **counsel:** stop pipefail from discarding all events on large logs :relieved: ([#78](https://github.com/onlooker-community/ecosystem/issues/78)) ([638347d](https://github.com/onlooker-community/ecosystem/commit/638347dec3b9df740b7a85c3e475fa2ffe5d054b))

## [0.26.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.25.1...ecosystem-v0.26.0) (2026-06-11)


### Features

* **counsel:** add /counsel on-demand weekly-review command :rocket: ([#76](https://github.com/onlooker-community/ecosystem/issues/76)) ([8ce951c](https://github.com/onlooker-community/ecosystem/commit/8ce951cd5cb7b173f194f86c2960a31fb0d6889d))

## [0.25.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.25.0...ecosystem-v0.25.1) (2026-06-10)


### Bug Fixes

* vendor portable-lock.sh into cartographer and governor ([#73](https://github.com/onlooker-community/ecosystem/issues/73)) ([ab2c354](https://github.com/onlooker-community/ecosystem/commit/ab2c354b131c26cc642ebb51e84a043dc43cbaa1))

## [0.25.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.24.0...ecosystem-v0.25.0) (2026-06-04)


### Features

* **assayer:** introduce claim-verification plugin ([#70](https://github.com/onlooker-community/ecosystem/issues/70)) ([1d0500b](https://github.com/onlooker-community/ecosystem/commit/1d0500b64f8cd670d1cfa1ac070182d72696bdfd))

## [0.24.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.23.1...ecosystem-v0.24.0) (2026-06-04)


### Features

* **librarian:** /librarian review skill closes promotion loop :tada: ([#68](https://github.com/onlooker-community/ecosystem/issues/68)) ([8f3e3db](https://github.com/onlooker-community/ecosystem/commit/8f3e3dbdf6f08dceb0cf61d46281936a4f9954de))

## [0.23.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.23.0...ecosystem-v0.23.1) (2026-06-04)


### Bug Fixes

* **scribe:** mark hook scripts executable :relieved: ([#64](https://github.com/onlooker-community/ecosystem/issues/64)) ([05603e5](https://github.com/onlooker-community/ecosystem/commit/05603e56895c009c1435d1712592adbbc4c15e61))

## [0.23.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.22.0...ecosystem-v0.23.0) (2026-06-04)


### Features

* **ecosystem:** emit memory.recalled at SessionStart :link: ([#62](https://github.com/onlooker-community/ecosystem/issues/62)) ([d5876f9](https://github.com/onlooker-community/ecosystem/commit/d5876f9f819165cc07d691d733662b549863b7f5))
* **historian:** retrieval pipeline + ollama embedder :telescope: ([#61](https://github.com/onlooker-community/ecosystem/issues/61)) ([7eae752](https://github.com/onlooker-community/ecosystem/commit/7eae752a288c4678ab093042469f2e65d428f0d9))

## [0.22.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.21.0...ecosystem-v0.22.0) (2026-06-04)


### Features

* **historian:** introduce SessionEnd indexing :spiral_notepad: ([#59](https://github.com/onlooker-community/ecosystem/issues/59)) ([dd6c7f6](https://github.com/onlooker-community/ecosystem/commit/dd6c7f6ea872437cab6b16de50838dfc72750c7b))

## [0.21.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.20.0...ecosystem-v0.21.0) (2026-06-04)


### Features

* **curator:** introduce plugin with cheap-tier checks :microscope: ([#57](https://github.com/onlooker-community/ecosystem/issues/57)) ([7f9fa18](https://github.com/onlooker-community/ecosystem/commit/7f9fa18bbde29c8b5bd1eaad185bd4c5595a3762))

## [0.20.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.19.0...ecosystem-v0.20.0) (2026-06-04)


### Features

* **librarian:** land plugin end-to-end with memory layer designs :seedling: ([#55](https://github.com/onlooker-community/ecosystem/issues/55)) ([d4821ef](https://github.com/onlooker-community/ecosystem/commit/d4821efabfeb587e460e898d7db8f92fcc3f2c61))

## [0.19.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.18.0...ecosystem-v0.19.0) (2026-06-02)


### Features

* **warden:** untrusted-content gate enforcing the Agents Rule of Two :shield: ([#53](https://github.com/onlooker-community/ecosystem/issues/53)) ([210aa51](https://github.com/onlooker-community/ecosystem/commit/210aa51bff66226a0eec1f17292a2af4ea4ef56a))

## [0.18.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.17.0...ecosystem-v0.18.0) (2026-06-02)


### Features

* **counsel:** weekly observability synthesis and coaching brief :robot: ([#51](https://github.com/onlooker-community/ecosystem/issues/51)) ([6364586](https://github.com/onlooker-community/ecosystem/commit/63645863cf3a1d7bbf0353aacb9b71e4f977dd56))

## [0.17.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.16.0...ecosystem-v0.17.0) (2026-06-01)


### Features

* **compass:** pre-write intent clarity gate plugin :compass: ([#47](https://github.com/onlooker-community/ecosystem/issues/47)) ([144c2ef](https://github.com/onlooker-community/ecosystem/commit/144c2ef44d28bab3dcec14a9eace7ec76470d090))
* **scribe:** intent documentation from agent activity :pencil2: ([#50](https://github.com/onlooker-community/ecosystem/issues/50)) ([f0a95d1](https://github.com/onlooker-community/ecosystem/commit/f0a95d1058e36d1bb5f0f645964d9e88e8f98b66))

## [0.16.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.15.2...ecosystem-v0.16.0) (2026-05-26)


### Features

* **governor:** resource governance and budget enforcement plugin :rocket: ([#43](https://github.com/onlooker-community/ecosystem/issues/43)) ([04e6d70](https://github.com/onlooker-community/ecosystem/commit/04e6d7051f27db752bb121d389d65b4d8ade04ad))

## [0.15.2](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.15.1...ecosystem-v0.15.2) (2026-05-25)


### Bug Fixes

* **tribunal:** persist all artifacts on every iteration including retries :relieved: ([#41](https://github.com/onlooker-community/ecosystem/issues/41)) ([1636105](https://github.com/onlooker-community/ecosystem/commit/163610535a4ce0fa73c8fb82dc5c6296d2d1065a))

## [0.15.1](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.15.0...ecosystem-v0.15.1) (2026-05-25)


### Bug Fixes

* **ci:** use paths_released to gate npm publish :rage: ([#37](https://github.com/onlooker-community/ecosystem/issues/37)) ([c62b17f](https://github.com/onlooker-community/ecosystem/commit/c62b17f7e1352cfe260a23c8f48be30f72edbbed))

## [0.15.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.14.0...ecosystem-v0.15.0) (2026-05-25)


### Features

* **cartographer:** add proactive instruction-file audit plugin :mag: ([#35](https://github.com/onlooker-community/ecosystem/issues/35)) ([387d00a](https://github.com/onlooker-community/ecosystem/commit/387d00ad04da5aae91048254ad0526bb674ed498))

## [0.14.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.13.0...ecosystem-v0.14.0) (2026-05-25)


### Features

* **echo:** add prompt regression detection plugin ([#32](https://github.com/onlooker-community/ecosystem/issues/32)) ([65274d4](https://github.com/onlooker-community/ecosystem/commit/65274d4d8326950d6c998ca292fed13b1b8c493b))

## [0.13.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.12.0...ecosystem-v0.13.0) (2026-05-24)


### Features

* **tribunal:** add multi-agent code review plugin :sparkles: ([#30](https://github.com/onlooker-community/ecosystem/issues/30)) ([893f24a](https://github.com/onlooker-community/ecosystem/commit/893f24a8876fdd6ccb5c7dcf2636a7c902e88949))

## [0.12.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.11.0...ecosystem-v0.12.0) (2026-05-23)


### Features

* **prompt-rules:** deterministic regex-triggered guidance injection :relieved: ([#28](https://github.com/onlooker-community/ecosystem/issues/28)) ([662c811](https://github.com/onlooker-community/ecosystem/commit/662c8119657cebc350900f859c43dbaca97d6703))

## [0.11.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.10.0...ecosystem-v0.11.0) (2026-05-23)


### Features

* **archivist:** introduce structured session memory plugin :rocket: ([378fff3](https://github.com/onlooker-community/ecosystem/commit/378fff3c14b40644af45b1a2335992e7b0428160))
* **coverage:** report node + bash coverage on every PR :sparkles: ([cb5d122](https://github.com/onlooker-community/ecosystem/commit/cb5d1221ad20e6257d66b507897dae14549a870f))
* **lint:** add marketplace cross-reference linter :nail_care: ([0f48817](https://github.com/onlooker-community/ecosystem/commit/0f488170326659ef1d0b8bd7ae4d207c78a43694))
* **lint:** add plugin manifest validator :nail_care: ([e12615f](https://github.com/onlooker-community/ecosystem/commit/e12615ff99d43caf59d5e215d882c0acb3352c01))


### Bug Fixes

* **hooks:** replace flock with portable mkdir mutex :bug: ([3dffa6f](https://github.com/onlooker-community/ecosystem/commit/3dffa6f5e43ef9f3c117f2406ddd03ce485df1cd))
* **release:** sync marketplace.json out-of-band :relieved: ([0d2a0a3](https://github.com/onlooker-community/ecosystem/commit/0d2a0a38c0c4ee0e400b9a143a4be7904ea3f70a))

## [0.10.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.9.0...ecosystem-v0.10.0) (2026-05-22)


### Features

* **hooks:** enrich tool.file.read with read chunking observability ([#25](https://github.com/onlooker-community/ecosystem/issues/25)) ([8eb23c8](https://github.com/onlooker-community/ecosystem/commit/8eb23c8f4f03dfbeb701a30de1fa50c1c8ee48ac))

## [0.9.0](https://github.com/onlooker-community/ecosystem/compare/ecosystem-v0.8.0...ecosystem-v0.9.0) (2026-05-22)


### Features

* add configuration and hooks for agent spawn tracking ([3ef4590](https://github.com/onlooker-community/ecosystem/commit/3ef459006bbbda246604bdd1ffaf9af0a59f9740))
* add settings.json for plugin configuration ([67fbdfe](https://github.com/onlooker-community/ecosystem/commit/67fbdfe37f067a45801e7d0355c4a533b687f6b2))
* **hooks:** add PreCompact and PostCompact context compaction trackers ([#15](https://github.com/onlooker-community/ecosystem/issues/15)) ([1ec5632](https://github.com/onlooker-community/ecosystem/commit/1ec5632404676ed8b35d324b79ad71a2e9093505))
* **hooks:** add SessionStart and SessionEnd session trackers ([#10](https://github.com/onlooker-community/ecosystem/issues/10)) ([a48d680](https://github.com/onlooker-community/ecosystem/commit/a48d680dd24c98e79ef1c0401b07483ecebf9e8b))
* **hooks:** add TaskCreated and TaskCompleted task lifecycle trackers ([#21](https://github.com/onlooker-community/ecosystem/issues/21)) ([986ffa8](https://github.com/onlooker-community/ecosystem/commit/986ffa84bdd857a464ca0d556671628190ed27bc))
* **hooks:** add UserPromptSubmit turn and session duration trackers ([#12](https://github.com/onlooker-community/ecosystem/issues/12)) ([cbb7657](https://github.com/onlooker-community/ecosystem/commit/cbb7657979ed144efce506e6b487e037679b9462))
* **hooks:** add WorktreeCreate and WorktreeRemove lifecycle trackers ([#24](https://github.com/onlooker-community/ecosystem/issues/24)) ([ff55e39](https://github.com/onlooker-community/ecosystem/commit/ff55e397a0c0adc3e76f66aba12c6b237149ad17))
* **hooks:** emit canonical schema events for tool history :sparkles: ([1e49a24](https://github.com/onlooker-community/ecosystem/commit/1e49a24bfb930942fa477b594395ef352618f574))
* **hooks:** track skill usage via skill.invoked events ([23fff0f](https://github.com/onlooker-community/ecosystem/commit/23fff0f0bfad8ab91788d8c45a0457d099d2e870))
* **hooks:** track tool call sequence on every PreToolUse :sparkles: ([0ad9546](https://github.com/onlooker-community/ecosystem/commit/0ad95465cc22a237e26115a67814a6e7b2951b1d))


### Bug Fixes

* **ci:** apply release-please extra-files for Claude plugin manifests ([#17](https://github.com/onlooker-community/ecosystem/issues/17)) ([da9913c](https://github.com/onlooker-community/ecosystem/commit/da9913ca4f7497280edc34f8c64baa903c1e6754))
* **ci:** checkout release tag before npm publish :relieved: ([bc7bbdc](https://github.com/onlooker-community/ecosystem/commit/bc7bbdc7a886a55ba8f04fe09bfa60043648c766))
* **ci:** grant id-token write for npm provenance on publish ([c78c9f0](https://github.com/onlooker-community/ecosystem/commit/c78c9f054c1d48ca8a83d0d26b76ce991fffe51b))
* **ci:** parse release-please paths_released JSON for npm publish ([749e1a0](https://github.com/onlooker-community/ecosystem/commit/749e1a02b563f37f81a8da21fc3f6e10e179314a))
* **ci:** stop upgrading npm globally before publish ([a7c7a0e](https://github.com/onlooker-community/ecosystem/commit/a7c7a0e1f25aee1bbb75bdd2af130dbc276480a6))
* **ci:** use HTTPS repository URL for npm provenance ([a7e8927](https://github.com/onlooker-community/ecosystem/commit/a7e89275c5a025a8afee009853265b717091f6ca))
* **package:** update repository URL format in package.json ([591ce9f](https://github.com/onlooker-community/ecosystem/commit/591ce9f54dd605ec04ceb77b9dcca40b3e08621e))

## [0.8.0](https://github.com/onlooker-community/ecosystem/compare/v0.7.2...v0.8.0) (2026-05-22)


### Features

* **hooks:** add TaskCreated and TaskCompleted task lifecycle trackers ([#21](https://github.com/onlooker-community/ecosystem/issues/21)) ([986ffa8](https://github.com/onlooker-community/ecosystem/commit/986ffa84bdd857a464ca0d556671628190ed27bc))

## [0.7.2](https://github.com/onlooker-community/ecosystem/compare/v0.7.1...v0.7.2) (2026-05-22)


### Bug Fixes

* **ci:** grant id-token write for npm provenance on publish ([c78c9f0](https://github.com/onlooker-community/ecosystem/commit/c78c9f054c1d48ca8a83d0d26b76ce991fffe51b))

## [0.7.1](https://github.com/onlooker-community/ecosystem/compare/v0.7.0...v0.7.1) (2026-05-22)


### Bug Fixes

* **ci:** parse release-please paths_released JSON for npm publish ([749e1a0](https://github.com/onlooker-community/ecosystem/commit/749e1a02b563f37f81a8da21fc3f6e10e179314a))

## [0.7.0](https://github.com/onlooker-community/ecosystem/compare/v0.6.0...v0.7.0) (2026-05-22)


### Features

* **hooks:** add PreCompact and PostCompact context compaction trackers ([#15](https://github.com/onlooker-community/ecosystem/issues/15)) ([1ec5632](https://github.com/onlooker-community/ecosystem/commit/1ec5632404676ed8b35d324b79ad71a2e9093505))


### Bug Fixes

* **ci:** apply release-please extra-files for Claude plugin manifests ([#17](https://github.com/onlooker-community/ecosystem/issues/17)) ([da9913c](https://github.com/onlooker-community/ecosystem/commit/da9913ca4f7497280edc34f8c64baa903c1e6754))


### Chores

* enhance release workflow for npm packages ([3b37b56](https://github.com/onlooker-community/ecosystem/commit/3b37b56270a13fec95c2cd6ee8816ba5725a680a))
* remove npm publish workflow ([5f29c33](https://github.com/onlooker-community/ecosystem/commit/5f29c33baca8c10289d48f8126dc6eb4b4fe8153))
* remove test job from npm publish workflow ([f25bf9d](https://github.com/onlooker-community/ecosystem/commit/f25bf9d65fbe5066fe9963ce8d075fe81dc8e5c9))

## [0.6.0](https://github.com/onlooker-community/ecosystem/compare/v0.5.0...v0.6.0) (2026-05-22)


### Features

* add settings.json for plugin configuration ([67fbdfe](https://github.com/onlooker-community/ecosystem/commit/67fbdfe37f067a45801e7d0355c4a533b687f6b2))

## [0.5.0](https://github.com/onlooker-community/ecosystem/compare/v0.4.0...v0.5.0) (2026-05-22)


### Features

* **hooks:** add UserPromptSubmit turn and session duration trackers ([#12](https://github.com/onlooker-community/ecosystem/issues/12)) ([cbb7657](https://github.com/onlooker-community/ecosystem/commit/cbb7657979ed144efce506e6b487e037679b9462))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/v0.3.3...v0.4.0) (2026-05-22)


### Features

* **hooks:** add SessionStart and SessionEnd session trackers ([#10](https://github.com/onlooker-community/ecosystem/issues/10)) ([a48d680](https://github.com/onlooker-community/ecosystem/commit/a48d680dd24c98e79ef1c0401b07483ecebf9e8b))

## [0.3.3](https://github.com/onlooker-community/ecosystem/compare/v0.3.2...v0.3.3) (2026-05-22)


### Chores

* enhance release workflow with conditional publishing ([d14a868](https://github.com/onlooker-community/ecosystem/commit/d14a86858dcdeb3ed87aa00985c2c79f9ca8a4d3))

## [0.3.2](https://github.com/onlooker-community/ecosystem/compare/v0.3.1...v0.3.2) (2026-05-22)


### Bug Fixes

* **ci:** stop upgrading npm globally before publish ([a7c7a0e](https://github.com/onlooker-community/ecosystem/commit/a7c7a0e1f25aee1bbb75bdd2af130dbc276480a6))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/v0.3.0...v0.3.1) (2026-05-22)


### Bug Fixes

* **ci:** use HTTPS repository URL for npm provenance ([a7e8927](https://github.com/onlooker-community/ecosystem/commit/a7e89275c5a025a8afee009853265b717091f6ca))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/v0.2.1...v0.3.0) (2026-05-21)


### Features

* **hooks:** track skill usage via skill.invoked events ([23fff0f](https://github.com/onlooker-community/ecosystem/commit/23fff0f0bfad8ab91788d8c45a0457d099d2e870))


### Chores

* update GitHub Actions permissions to include id-token ([ca18e61](https://github.com/onlooker-community/ecosystem/commit/ca18e61571b173d1aa6e69cf9031d2daaae1ff72))
* update npm publish configuration in release workflow ([261fa2d](https://github.com/onlooker-community/ecosystem/commit/261fa2d5c9d656ce74f52193be615b860bc78075))

## [0.2.1](https://github.com/onlooker-community/ecosystem/compare/v0.2.0...v0.2.1) (2026-05-21)


### Bug Fixes

* **ci:** checkout release tag before npm publish :relieved: ([bc7bbdc](https://github.com/onlooker-community/ecosystem/commit/bc7bbdc7a886a55ba8f04fe09bfa60043648c766))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/v0.1.0...v0.2.0) (2026-05-21)


### Features

* **hooks:** emit canonical schema events for tool history :sparkles: ([1e49a24](https://github.com/onlooker-community/ecosystem/commit/1e49a24bfb930942fa477b594395ef352618f574))
* **hooks:** track tool call sequence on every PreToolUse :sparkles: ([0ad9546](https://github.com/onlooker-community/ecosystem/commit/0ad95465cc22a237e26115a67814a6e7b2951b1d))


### Chores

* **deps:** use published @onlooker-community/schema from npm :relieved: ([efc92d8](https://github.com/onlooker-community/ecosystem/commit/efc92d8171592aa5a5f1c27853387e810fee612f))

## [0.1.0](https://github.com/onlooker-community/ecosystem/compare/v0.0.3...v0.1.0) (2026-05-21)


### Features

* add configuration and hooks for agent spawn tracking ([3ef4590](https://github.com/onlooker-community/ecosystem/commit/3ef459006bbbda246604bdd1ffaf9af0a59f9740))


### Chores

* clean up README.md by removing outdated badge links ([42d47d6](https://github.com/onlooker-community/ecosystem/commit/42d47d602aa7b68db719874a1cf4193433d1bd68))
* remove skills from plugin.json to streamline configuration ([fdfd8eb](https://github.com/onlooker-community/ecosystem/commit/fdfd8eb4faa0c807eff97feb1a20961de1fe154d))

## [0.0.3](https://github.com/onlooker-community/ecosystem/compare/v0.0.2...v0.0.3) (2026-05-21)


### Chores

* update release-please configuration to include custom pull request title pattern ([e860f1c](https://github.com/onlooker-community/ecosystem/commit/e860f1c5a7b58909a53ec38a3b3da89f22f0434c))

## [0.0.2](https://github.com/onlooker-community/ecosystem/compare/v0.0.1...v0.0.2) (2026-05-21)


### Chores

* add .gitignore, update markdownlint configuration, and enhance biome.json settings ([edb47ed](https://github.com/onlooker-community/ecosystem/commit/edb47ed84d847f704668e99ac43e5613e25ab19f))
* add initial project files including configuration, scripts, and license ([dc2a803](https://github.com/onlooker-community/ecosystem/commit/dc2a8034fd5243c2d1a427ad13c0dcef2e92f713))
* initial commit ([71f1f79](https://github.com/onlooker-community/ecosystem/commit/71f1f7993cac154138ea0f8f0db6560a2624bfff))

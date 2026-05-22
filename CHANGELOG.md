# Changelog

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

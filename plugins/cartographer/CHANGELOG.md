# Changelog

All notable changes to the Cartographer plugin are documented here.

## [0.7.7](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.7.6...cartographer-v0.7.7) (2026-09-06)


### Bug Fixes

* **events:** emit through the newest ecosystem, not the first one listed :satellite: ([#276](https://github.com/onlooker-community/ecosystem/issues/276)) ([1b3541c](https://github.com/onlooker-community/ecosystem/commit/1b3541c8bbeaf9c00a992ee339e2a726fa9e087c))

## [0.7.6](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.7.5...cartographer-v0.7.6) (2026-09-05)


### Bug Fixes

* **hooks:** attribute nested sessions to their own id :straight_ruler: ([#252](https://github.com/onlooker-community/ecosystem/issues/252)) ([74b34ec](https://github.com/onlooker-community/ecosystem/commit/74b34ecdc038d1e90b7a236077601ea1b6ec9ee8))

## [0.7.5](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.7.4...cartographer-v0.7.5) (2026-09-03)


### Bug Fixes

* **defaults:** ship path defaults that match repos other than this one :broom: ([#241](https://github.com/onlooker-community/ecosystem/issues/241)) ([aa44b98](https://github.com/onlooker-community/ecosystem/commit/aa44b98b320ab88208481b094f8f8032921fdd71))


### Performance Improvements

* **clock:** stop paying python3 to ask what time it is :zap: ([#239](https://github.com/onlooker-community/ecosystem/issues/239)) ([2be081c](https://github.com/onlooker-community/ecosystem/commit/2be081c36ac7dd907ca55ce49bba51764aeb4396))

## [0.7.4](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.7.3...cartographer-v0.7.4) (2026-09-03)


### Bug Fixes

* **config:** honor CLAUDE_CONFIG_DIR for user settings :mag: ([#237](https://github.com/onlooker-community/ecosystem/issues/237)) ([057a40d](https://github.com/onlooker-community/ecosystem/commit/057a40d65d221dadef9d6fda235c87e032375235))

## [0.7.3](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.7.2...cartographer-v0.7.3) (2026-09-02)


### Bug Fixes

* **lock:** break the abandoned locks reclamation was built for :relieved: ([#233](https://github.com/onlooker-community/ecosystem/issues/233)) ([887e227](https://github.com/onlooker-community/ecosystem/commit/887e227c7f68c379e1ade239e9e9e322e7b2ce35))

## [0.7.2](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.7.1...cartographer-v0.7.2) (2026-09-01)


### Bug Fixes

* **lock:** reclaim a lock whose holder was killed :relieved: ([#227](https://github.com/onlooker-community/ecosystem/issues/227)) ([32bde03](https://github.com/onlooker-community/ecosystem/commit/32bde034bbb70d5f85120abceea2cfa337526d12))

## [0.7.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.7.0...cartographer-v0.7.1) (2026-08-30)


### Bug Fixes

* **hook-health:** make duration_ms mean what it claims :straight_ruler: ([#215](https://github.com/onlooker-community/ecosystem/issues/215)) ([0db5750](https://github.com/onlooker-community/ecosystem/commit/0db57505a8beb1fee915457875ed45018de0ec40))

## [0.7.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.6.3...cartographer-v0.7.0) (2026-08-29)


### Features

* **hook-health:** measure latency for every plugin hook :bar_chart: ([#213](https://github.com/onlooker-community/ecosystem/issues/213)) ([afcc9ff](https://github.com/onlooker-community/ecosystem/commit/afcc9ffebb206a78330f03a17f82b20198873c37))

## [0.6.3](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.6.2...cartographer-v0.6.3) (2026-08-29)


### Bug Fixes

* **plugins:** vendor config-loader.sh into every plugin :relieved: ([#209](https://github.com/onlooker-community/ecosystem/issues/209)) ([b23c291](https://github.com/onlooker-community/ecosystem/commit/b23c291a1283324171a6fd414a2ecc7b3e766eb4))

## [0.6.2](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.6.1...cartographer-v0.6.2) (2026-08-23)


### Bug Fixes

* **cartographer:** drop a typeless finding instead of hashing it as "unknown" :broom: ([#203](https://github.com/onlooker-community/ecosystem/issues/203)) ([a949d5d](https://github.com/onlooker-community/ecosystem/commit/a949d5d43f3ae3515ac6278b35d1be5cc468cb0e))

## [0.6.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.6.0...cartographer-v0.6.1) (2026-08-22)


### Bug Fixes

* **config:** let every config lib find the loader from its own path :broom: ([#198](https://github.com/onlooker-community/ecosystem/issues/198)) ([249fe41](https://github.com/onlooker-community/ecosystem/commit/249fe41bf191db48239c2028ba77a10b3dcb03af))

## [0.6.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.5.1...cartographer-v0.6.0) (2026-08-19)


### Features

* **cartographer:** announce a finding when its drift is gone :wave: ([#186](https://github.com/onlooker-community/ecosystem/issues/186)) ([f2b57f6](https://github.com/onlooker-community/ecosystem/commit/f2b57f67b3e09f7ec624bce0bb4a306c4e20df8b))

## [0.5.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.5.0...cartographer-v0.5.1) (2026-08-19)


### Bug Fixes

* **cartographer:** refuse a typeless finding out loud :loudspeaker: ([#182](https://github.com/onlooker-community/ecosystem/issues/182)) ([35ee0af](https://github.com/onlooker-community/ecosystem/commit/35ee0af055fd360a70a77d6ef036bbeb91dcc945))

## [0.5.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.4.3...cartographer-v0.5.0) (2026-08-18)


### Features

* **cartographer:** narrow an audit by finding type or subtree :mag: ([#177](https://github.com/onlooker-community/ecosystem/issues/177)) ([94764df](https://github.com/onlooker-community/ecosystem/commit/94764dfc8386521a06c8234bc506cb51a667588d))


### Bug Fixes

* **librarian:** stop stage 5 from holding a session open :hourglass: ([#178](https://github.com/onlooker-community/ecosystem/issues/178)) ([4f12a1e](https://github.com/onlooker-community/ecosystem/commit/4f12a1ee25300e0dc372542814e0922df5dbd335))

## [0.4.3](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.4.2...cartographer-v0.4.3) (2026-08-17)


### Bug Fixes

* **cartographer:** make the audit read the settings you gave it :gear: ([#174](https://github.com/onlooker-community/ecosystem/issues/174)) ([dc57731](https://github.com/onlooker-community/ecosystem/commit/dc5773165fe561f77e87101ed1fbe6e13bb34c34))

## [0.4.2](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.4.1...cartographer-v0.4.2) (2026-08-17)


### Bug Fixes

* **cartographer:** let a finding you fixed finally go away :wastebasket: ([#172](https://github.com/onlooker-community/ecosystem/issues/172)) ([c8fdcf4](https://github.com/onlooker-community/ecosystem/commit/c8fdcf40b711b68ee5d90e2c4b6408ea38926900))

## [0.4.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.4.0...cartographer-v0.4.1) (2026-08-17)


### Bug Fixes

* **cartographer:** put its events on the bus for the first time :mega: ([#170](https://github.com/onlooker-community/ecosystem/issues/170)) ([91be8d2](https://github.com/onlooker-community/ecosystem/commit/91be8d2c9f171006db12842f3e582d001f9d4e27))

## [0.4.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.3.1...cartographer-v0.4.0) (2026-08-16)


### Features

* **cartographer:** detect what no instruction file mentions :eyes: ([#168](https://github.com/onlooker-community/ecosystem/issues/168)) ([31efb7b](https://github.com/onlooker-community/ecosystem/commit/31efb7b035665d5a49a37c1e1af21f519850f7bd))

## [0.3.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.3.0...cartographer-v0.3.1) (2026-08-01)


### Bug Fixes

* **plugins:** glob-discover ecosystem root so sub-plugins work from cache :relieved: ([#110](https://github.com/onlooker-community/ecosystem/issues/110)) ([3639240](https://github.com/onlooker-community/ecosystem/commit/3639240383e1b820e5d8ea42639e0b863ef0d90e))

## [0.3.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.2.1...cartographer-v0.3.0) (2026-07-03)


### Features

* **plugins:** installation enables plugins — remove per-plugin 'enabled' config key ([#108](https://github.com/onlooker-community/ecosystem/issues/108)) ([45e4e6b](https://github.com/onlooker-community/ecosystem/commit/45e4e6bd29a0a7545dbd5007bf3f09600e1be391))

## [0.2.1](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.2.0...cartographer-v0.2.1) (2026-06-10)


### Bug Fixes

* vendor portable-lock.sh into cartographer and governor ([#73](https://github.com/onlooker-community/ecosystem/issues/73)) ([ab2c354](https://github.com/onlooker-community/ecosystem/commit/ab2c354b131c26cc642ebb51e84a043dc43cbaa1))

## [0.2.0](https://github.com/onlooker-community/ecosystem/compare/cartographer-v0.1.0...cartographer-v0.2.0) (2026-05-25)


### Features

* **cartographer:** add proactive instruction-file audit plugin :mag: ([#35](https://github.com/onlooker-community/ecosystem/issues/35)) ([387d00a](https://github.com/onlooker-community/ecosystem/commit/387d00ad04da5aae91048254ad0526bb674ed498))

## [0.1.0](https://github.com/onlooker-community/ecosystem/releases/tag/cartographer-v0.1.0) (2026-05-25)

### Added

- SessionStart hook with interval gate and non-blocking background audit launch (`nohup setsid`)
- PostToolUse hook on Write/Edit/MultiEdit with exact `basename(realpath(...))` matching for CLAUDE.md files
- Five-phase audit pipeline: discover → extract → relate → synthesize → emit
- LLM-assisted analysis for contradictions, stale references, dead rules, and scope collisions
- `flock`-based cross-session audit lock with PID-file fallback for macOS
- Commutative `finding_hash` (SHA256) for stable finding identity across audit runs
- Atomic finding writes (`*.tmp` + `mv -f`) and `dedup/<hash>` sentinel store
- At-least-once `cartographer.issue.found` event delivery; documented dedup contract
- `/cartographer` skill with `--verbose`, `--status`, `--force`, `--scope`, and `--phase` flags
- Four ADRs documenting key design decisions
- Default `exclude_paths` covering `node_modules`, `.git`, `vendor`, `.venv`, and common build dirs
- `enabled: false` default — opt-in activation via `.claude/settings.json`

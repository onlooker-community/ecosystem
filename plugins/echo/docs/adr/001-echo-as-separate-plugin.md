# ADR-001: Echo as a Separate Plugin, Not an Extension of Tribunal

**Status:** Accepted  
**Date:** 2026-05-24

## Context

Tribunal already exists as an evaluation engine in this ecosystem. When designing Echo's prompt-change regression detection, the first question was whether Echo should live inside Tribunal (as a sub-feature or mode) or stand alone as its own plugin.

The Tribunal team ran a formal evaluation of this question using Tribunal itself. The final score across three iterations was 0.79 (above the 0.75 acceptance threshold), with outcome `exhausted_iterations` — the adversarial judge never passed, which is expected behavior for that judge type. The substantive conclusion from all three iterations was: Echo is architecturally sound as a standalone plugin.

## Decision

Echo is a separate, independent plugin under `plugins/echo/`.

## Rationale

**Separate concerns.** Tribunal is an orchestrator for arbitrary tasks. Echo is a specialized harness for prompt quality regression testing. Bundling Echo into Tribunal would couple two distinct concerns: general task evaluation and change-detection/baselining.

**Different lifecycle.** Tribunal is always on (for `/tribunal` skill invocations) and opt-in for its Stop hook. Echo is opt-in by default (`"enabled": false`) and has no interactive skill surface — it only runs as a Stop hook. These are different activation patterns that would conflict if forced into the same plugin config namespace.

**Independent versioning.** Echo and Tribunal can release, iterate, and break/fix independently. Echo v0.2 does not need to drag along a Tribunal major bump.

**Composability.** Echo today calls `claude -p` directly. A future version could delegate to Tribunal for richer multi-judge evaluation (see ADR-002). That migration is easier when Echo is its own entry point.

**Self-exclusion.** Echo must never trigger on its own files changing. This is simpler to enforce as a first-class concern in a standalone plugin (`plugins/echo/**` is always in `exclude_paths`) than as a special case inside Tribunal.

## Consequences

- Echo requires the ecosystem plugin but does **not** require Tribunal to be installed.
- Echo gets its own `config.json`, `hooks.json`, `.claude-plugin/plugin.json`, CHANGELOG, and release-please track.
- Any future Tribunal integration (e.g., Echo delegating multi-judge eval to Tribunal) will be an opt-in config option, not a hard dependency.
- Marketplace listing and docs must be careful not to imply Tribunal is a prerequisite (an early draft of the description made this mistake; corrected before merge).

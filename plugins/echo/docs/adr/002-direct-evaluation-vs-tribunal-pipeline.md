# ADR-002: Direct `claude -p` Evaluation vs. Routing Through Tribunal's Pipeline

**Status:** Accepted (with planned future extension)  
**Date:** 2026-05-24

## Context

Echo needs to evaluate prompt file quality before and after a change. Two approaches were available:

**Option A — Direct `claude -p`**: Build an inline rubric prompt, call `claude -p --max-turns 1` for each file, and parse the JSON score from the response.

**Option B — Tribunal pipeline**: Invoke Tribunal's multi-judge Actor → Jury → Meta-Judge → Gate loop for each file and use the aggregated score as the quality signal.

## Decision

Echo v0.1 uses **Option A** — direct `claude -p` with an inline rubric.

## Rationale

**Stop hook latency budget.** A Stop hook fires synchronously at the end of every session. Tribunal's full loop (Actor + two judges + Meta-Judge + Gate, with potential retries) takes 30–120 seconds per task. Multiplied across several watched files, this would make sessions feel like they hang after every edit. A single `claude -p` call with a 60-second timeout keeps the overhead acceptable.

**Echo evaluates prompts, not outputs.** Tribunal's loop is designed to evaluate an Agent's *work product* against a rubric. Echo evaluates *the prompt file itself* — a simpler, single-document task. A full jury is architecturally overweight for this use case.

**Baseline stability.** Tribunal's multi-judge scores have meaningful variance across runs (different judge models, adversarial judge behavior, Meta-Judge overrides). Echo's baseline comparison depends on stable, reproducible scores — a single `claude -p` pass with a fixed model and rubric is more consistent as a yardstick.

**Haiku is cheap enough.** Evaluating a prompt file with Haiku costs a fraction of a cent. Running a full Tribunal loop (Opus-class models for judges) would cost 10–50× more per file per session. With a default model of `claude-haiku-4-5-20251001`, Echo can run automatically without raising cost concerns.

**Independent of Tribunal installation.** Option A requires only the `claude` CLI. Option B would make Tribunal a hard runtime dependency of Echo, coupling two plugins that have separate versioning and installation paths (see ADR-001).

## Consequences

- Echo's evaluation quality is bounded by a single-model, single-pass rubric. It will miss issues that a diverse jury would catch, but it is consistent enough to detect regressions.
- The scoring rubric (role clarity, output format, criterion coverage, internal consistency) is hardcoded in the hook rather than being user-overridable in v0.1. A future version should expose this as config.
- A future `echo.mode: "tribunal"` config option could delegate to Tribunal's jury for higher-confidence evaluation when cost and latency are acceptable. The current design leaves room for this — Echo's event schema (`echo.suite.started`, etc.) is agnostic to the underlying evaluator.
- The `claude -p` response parsing includes a `sed` strip for accidental markdown fences, which Tribunal's pipeline avoids by using structured judge output. This is a fragility to watch.

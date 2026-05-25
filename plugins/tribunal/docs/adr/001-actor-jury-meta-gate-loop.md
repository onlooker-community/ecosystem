# ADR-001: The Actor → Jury → Meta-Judge → Gate Loop

**Status:** Accepted  
**Date:** 2026-05-24

## Context

Tribunal needs a structure for producing high-quality output from an LLM. The simplest approach is a single model call and accept whatever comes out. More rigorous options include self-critique, a second model reviewing the first, or a multi-agent panel. The design choices were:

- **Single pass** — one model, no review.
- **Self-critique** — the same model reviews its own output.
- **Two-model review** — a separate "judge" model scores the first model's output.
- **Multi-agent jury** — multiple typed judge agents score the output; a meta-judge reviews the jury for bias; a gate decides accept/retry.

## Decision

Tribunal uses a **four-tier Actor → Jury → Meta-Judge → Gate loop** with configurable retry.

This design is grounded in two published findings:
- [LLM-as-a-Judge (Zheng et al. 2023)](https://arxiv.org/abs/2306.05685): strong LLMs can score other LLMs against rubrics with reasonable agreement to human judgment.
- [LLM-as-a-Meta-Judge (Wu et al. 2024)](https://arxiv.org/abs/2407.19594): a second model reviewing the Judge's verdict catches position bias, verbosity bias, and self-enhancement — bias types that degrade single-judge reliability.

## Rationale

**Single pass is insufficient for high-stakes tasks.** A model that produces and evaluates its own output is subject to self-enhancement bias — it tends to rate its own output favorably. Separate the producer (Actor) from the evaluators (Jury).

**A jury of typed judges catches different failure modes.** A `standard` judge scores correctness and completeness. An `adversarial` judge actively tries to find failure modes. A `security` judge looks for vulnerabilities. No single judge type is best at everything; the jury composition is configurable per project.

**The Meta-Judge addresses jury bias, not just actor quality.** Even separate judge models have documented bias patterns: position bias (favoring the first response), verbosity bias (favoring longer outputs), sycophancy. The Meta-Judge reviews each verdict for these patterns and can flag or override. Without this tier, jury disagreement is unresolvable — you can't know if one judge was right or biased.

**The Gate with retry closes the loop.** A quality gate that only reports a score doesn't improve outcomes. By feeding the jury's critique back to the Actor on retry, Tribunal creates a feedback loop. The Actor on iteration 1 sees what the judges found weak; it has a chance to produce better output before the session ends.

**Configurable `max_iterations` prevents infinite loops.** The loop always terminates. `max_iterations: 3` (default) means at most 3 Actor passes. If the gate never passes, the outcome is `exhausted_iterations` — not a hang.

## Consequences

- A full Tribunal loop with two judges and a Meta-Judge makes 4–5 model calls per iteration. At 3 iterations, this is 12–15 calls. Cost and latency are real concerns; Tribunal is designed for deliberate use (`/tribunal <task>`), not for wrapping every session automatically.
- The `majority` gate policy with two judges creates a degenerate case: 2-judge majority requires 2/2 judges to pass (not 1/2). This surprised early users expecting 50%+1. See ADR-002 for the gate policy decision.
- Judge type composition matters. The default `["standard", "adversarial"]` provides coverage and contrast. Adding `security` triples judge cost for every iteration.
- The Actor receives critique from *all* prior judges on retry, not just the weakest. This is intentional — even a judge that passed may have noted improvements.

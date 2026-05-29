# ADR-001: Compass Evaluates Prompts-in-Context, Not Prompts-in-Isolation

- Status: Accepted
- Date: 2026-04-20
- Deciders: Meagan
- Tags: compass, oracle, calibration, convergence-sampling, hook-architecture

## Context and Problem Statement

Compass's `PreToolUse` hook evaluates each pending write operation using the tool call arguments and a short context excerpt from the conversation. When a user replies to a question the agent just asked — e.g., answering "Let's do 3, both" to an enumerated menu in the prior assistant turn — Compass flags the write that follows as uncertain and blocks progress.

The write is not actually ambiguous. The ambiguity-resolving information lives in the prior assistant turn (the menu), which the hook payload does not see. Compass is correctly executing a subtly wrong specification: its convergence test asks whether two independent readers of the context *alone* would converge, and for context-dependent replies ("option 2", "both", "do the first one", "yes"), the answer in isolation is always no.

This produces a class of false positives that undermines Compass's usefulness in the most common conversational pattern: the agent asks a clarifying question, the user answers it, work proceeds. Under the current design, every write that follows such an answer risks being flagged — not because the user was unclear, but because Compass is blind to what was asked.

The failure mode is most visible in multi-turn flows where the agent itself has done the disambiguation work (listing options, asking targeted questions) and the user is simply selecting. Those are precisely the moments where calibration should be cheapest, not most expensive.

## Decision Drivers

- **False-positive cost is high**: every incorrect flag interrupts the user and forces them to restate context the conversation already established.
- **Compass's stated value is catching misaligned-but-confident work**: the design should preserve suspicion of genuinely ambiguous writes while not penalizing legitimate context-dependent replies.
- **Jeong & Son design principle**: declare what you can, reflect symbolically where possible, reserve the LLM for the residual. Answering a menu is a declarable case; it should not require LLM calibration at all.
- **Hook architecture constraint**: Claude Code hooks receive event payloads, not full transcripts by default. Any fix must be compatible with the payload model.
- **Tribunal design precedent**: when an evaluator reasons about the quality of its own output, giving it the right substrate to reason over is the load-bearing decision. Tribunal's Actor works because it has access to its full task description; Compass's evaluator needs the same structural access to the turn it is calibrating.

## Considered Options

1. **Make Compass less suspicious overall.** Raise the confidence threshold so borderline cases pass.
2. **Evaluate prompts-in-context.** Pass the prior assistant turn into the evaluator payload so the convergence test operates on the pair `{prior_assistant_turn, current_context}`.
3. **Symbolic skip pattern for question-answers.** Detect when the prior assistant turn ends in an enumerated question and the user prompt references an option; skip LLM calibration entirely for that case.
4. **Integrate with Archivist.** Query Archivist's extracted turn-pair rather than reading the transcript directly.

## Decision

We adopt **Option 2 (evaluate prompts-in-context) as the architectural baseline, combined with Option 3 (symbolic skip pattern) as an optimization layer**.

Option 2 establishes the correct unit of analysis: Compass's convergence test will evaluate whether two independent readers *with access to the prior assistant turn* would converge on the same interpretation of the pending write. This is the minimal change that resolves the specification bug without weakening Compass's core function.

Option 3 layers on top: before invoking the LLM evaluator, Compass performs a cheap symbolic check. If the prior turn ends in an enumerated question (pattern: numbered list with `?` somewhere in the turn) and the current prompt references an option ("1", "option 2", "both", "do 3", "the first one", "yes", "no"), Compass short-circuits to `confident` without an LLM call. This is the Jeong & Son move: most answers to Claude's own questions are declarable; the LLM is reserved for the genuinely ambiguous residual.

Option 1 is rejected because it weakens Compass uniformly, including for writes where suspicion is warranted. Option 4 is deferred; it is a clean longer-term integration but introduces a cross-plugin dependency that Compass does not currently have, and Option 2 is a prerequisite in any case.

## Consequences

### Positive

- False positives on question-answer turns drop substantially (expected near-zero for the enumerated-menu case once Option 3 lands).
- Compass's convergence test operates on the correct unit of analysis, aligning specification with intent.
- The symbolic skip pattern reduces LLM invocation rate on a large class of turns, lowering latency and cost.
- The architectural decision is inspectable and traceable: the substrate change (prior-turn context) is separate from the symbolic optimization (skip pattern), so each can be evaluated independently.

### Negative

- The hook payload grows: it must now include the prior assistant turn, which means reading from the transcript or session log. This adds I/O per evaluation and introduces timing-skew risk (the prior turn's event may not yet be flushed when the `PreToolUse` hook fires).
- The symbolic skip pattern introduces a regex-based heuristic whose failure modes (false negatives on creatively-phrased answers, false positives on reply-shaped prompts that aren't actually answers) need monitoring.
- Edge cases appear: what counts as "the prior assistant turn" when the user sends multiple messages in sequence, or when the prior turn was a tool result rather than a conversational reply? These need explicit handling.

### Neutral

- Archivist integration (Option 4) remains available as a future refactor. If Archivist becomes the canonical source of recent turn structure, Compass's transcript-reading logic can be replaced with an Archivist query without changing the architectural decision recorded here.

## Implementation Notes

- The hook script reads the most recent assistant turn from the session transcript. The transcript path is provided as `transcript_path` in the hook JSON payload (consistent with how `tribunal-stop-gate.sh` reads it: `jq -r '.transcript_path // ""'`). If `transcript_path` is absent or the file is unreadable, the hook proceeds with an empty `prior_assistant_turn`. The Onlooker event log is not a fallback — `session.prompt` events record user-prompt telemetry, not assistant-turn content.
- Compass's evaluator prompt is updated to use a structured pair: `<prior_assistant_turn>` and `<context_excerpt>` as separate XML-delimited slots. The convergence question is phrased as: "Given the prior assistant turn as context, would two independent readers converge on the same interpretation of this write?"
- The symbolic skip pattern is implemented in bash using `jq` and regex, consistent with the plugin's hook style.
- Skip-pattern decisions are logged as `compass.check.skipped` with `reason: "reply_to_question_pattern"` so false-negative and false-positive rates can be measured.
- A new `skip_patterns.reply_to_question.enabled` config key (default: `true`) toggles the symbolic layer.

## Validation

This decision is validated by running Compass against multi-turn conversations where the current implementation produces false interventions on question-answer turns. Expected outcomes:

- Reply-to-question turns (answered with option references) short-circuit to `confident` under the skip pattern.
- Reply-to-question turns with genuine ambiguity (e.g., "both, but only if it's easy") still reach the LLM evaluator, now with prior-turn context, and produce a meaningful calibration state.
- Non-reply prompts (new requests, unrelated pivots) are unaffected by the skip pattern and continue through normal evaluation.

## References

- Jeong & Son (2026), *How Much LLM Does a Self-Revising Agent Actually Need?* (arXiv:2604.07236) — declarative substrate principle
- Tribunal ADR-001 — evaluator substrate precedent: evaluators need structural access to what they evaluate
- Compass design document (`plugins/compass/docs/design.md`)

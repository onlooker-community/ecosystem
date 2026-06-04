# ADR-001: Verify Claims at Stop Against Transcript Evidence

- Status: Accepted
- Date: 2026-06-04
- Deciders: Meagan
- Tags: assayer, verification, stop-hook, transcript, honesty

## Context and Problem Statement

Every other plugin in the ecosystem assumes the agent's account of its own work is true. Tribunal judges the output, echo scores the prompt, governor counts the spend — but none of them check the most basic thing: when the agent says "I ran the tests and they pass," did the tests actually pass?

This failure mode is not malice. An agent claims success because it intended to verify, or it verified an earlier revision, or it ran the command, saw red, fixed something, and never re-ran. The final message reflects a belief, and the belief can be stale. The session transcript already holds the ground truth — the commands that ran and whether they errored — but nothing reconciles the two.

The question: **how do we check the agent's claims against what actually happened, cheaply and without false alarms?**

## Decision Drivers

- The evidence (commands + results) must already exist and be trustworthy — not reconstructed or re-run.
- Verification must be deterministic: the same session must always produce the same verdict.
- False positives are expensive. Flagging a true claim as a lie destroys trust in the plugin faster than missing a false one.
- It must not interrupt the user's flow for an advisory signal.

## Decision

**Assayer runs at `Stop`, reads the session transcript, and reconciles the agent's final-message claims against the Bash command results recorded in that same transcript.**

Three sub-decisions follow:

### 1. Stop, reading the committed transcript

`Stop` fires once the turn is over and the transcript is fully written to disk — the same `transcript_path` tribunal and compass read. There is no timing-skew risk: every command the agent ran, and every result, is already on disk before assayer looks. Running earlier (e.g. `PostToolUse`) would mean verifying claims that have not been made yet.

### 2. `is_error`, not exit codes

Claude Code's transcript represents a command as a `tool_use` block and its outcome as a `tool_result` carrying an `is_error` boolean. It does **not** expose a per-call numeric exit code. So `is_error` is the success/failure signal: a claim of success contradicted by a matching command whose `is_error` is true. The schema's `assayer.claim.contradicted` payload reflects this honestly — `evidence_command` is required, `exit_code` is optional (populated only when a code is recoverable from output), and a `result_excerpt` captures the failing output for the reader.

### 3. Split the work: LLM identifies, bash verifies

Claim extraction is a language problem — what counts as a testable success claim, and what command would settle it — so an LLM (`claude -p`, Haiku) does it. The factual cross-check is not a language problem; it is a lookup. So a deterministic bash/jq verifier matches each claim to the most recent command containing its keywords and reads `is_error`. The LLM never judges truth; the verifier never interprets language. This keeps the verdict reproducible and unit-testable, and confines the non-determinism to the one step that genuinely needs it.

### 4. Advisory, not blocking

Assayer always exits 0. A contradicted claim is emitted as an event and written to an advisory file, not used to block `Stop`. The turn is already over; the high-value action is a durable, queryable signal ("the agent claimed X; the evidence says otherwise"), not interrupting a finished session. A blocking/enforce mode that re-prompts the agent on contradiction is a plausible future opt-in, but the safe default is advisory.

## Consequences

**Positive**

- Closes the "did it actually work?" gap with zero new infrastructure — the evidence is already in the transcript.
- Deterministic and testable: the verifier is pure bash/jq with no LLM in the factual path.
- Off by default and advisory, so it can never block or surprise a session it was not invited to.

**Negative / accepted trade-offs**

- Keyword matching is heuristic. A claim whose verifying command uses unexpected wording falls to `unverified` rather than being checked — a miss, not a false alarm, which is the safer direction to err.
- `is_error` is coarser than an exit code. A command that exits 0 but prints failures (a test runner that swallows its own status) reads as success. Documented; acceptable for v0.1.
- One `claude -p` call per Stop. This is why the plugin is off by default.

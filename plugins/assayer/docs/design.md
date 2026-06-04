# Assayer — Design

Assayer is the verification layer of the Onlooker ecosystem. Where tribunal judges *quality* and echo tracks *prompt drift*, assayer answers a narrower, more literal question: **did the things the agent said it did actually happen?**

## The problem: lying-without-malice

An agent's final message is a self-report. It says "tests pass," "build is green," "lint is clean." These read as facts but are really *beliefs*, and beliefs drift from reality in ordinary ways:

- The agent ran the check against an earlier revision, then changed code, and never re-ran.
- It intended to run the check and narrated as if it had.
- It misread a noisy command's output.

None of this is deception. But a user who trusts the self-report ships on a false premise. The session transcript already contains the ground truth — every command and its result — so the gap is purely one of reconciliation.

## Pipeline

```
Stop
  → Transcript Reader      (final message + commands-with-status)
  → Claim Extractor        (claude -p, Haiku — language understanding)
  → Deterministic Verifier (bash/jq — factual lookup)
  → Events + advisory file
```

### Transcript reader (`assayer-transcript.sh`)

Two extractions from the JSONL transcript at `transcript_path`:

- `assayer_final_assistant_message` — the text blocks of the last assistant turn that contains any, truncated to `final_message_chars`. This is where claims live.
- `assayer_collect_commands` — every `Bash` `tool_use` joined to its `tool_result` by `tool_use_id`, yielding `{ command, is_error, excerpt }`. Claude Code does not record a numeric exit code per call; `is_error` is the success/failure signal. See ADR-001.

### Claim extractor (`assayer-extract.sh`)

A single `claude -p` pass reads only the final message and returns a JSON array of claims, each `{ text, type, command_keyword, confidence }`. `type` is one of `tests_pass | build_succeeds | lint_clean | types_check | command_succeeds | generic`. The model identifies claims and what command would settle them; it does not judge whether they are true. `assayer_parse_claims` strips fences, validates the array, coerces unknown types to `generic`, and drops entries without text.

### Deterministic verifier (`assayer-verify.sh`)

`assayer_classify_claim` derives keywords from the claim's `type` (e.g. `tests_pass → ["test"]`) plus the LLM-supplied `command_keyword`, finds the **most recent** command containing any keyword, and classifies on its `is_error`:

- matched + not errored → **corroborated**
- matched + errored → **contradicted**
- no match → **unverified** (`no_matching_command`, or `ambiguous` when the claim implies no checkable command)

"Most recent wins" handles the fail-fix-rerun pattern: the last run reflects the final state. The function is pure — no LLM, no filesystem — so it is fully unit-tested.

`assayer_audit_verdict` rolls the per-claim counts into `clean`, `contradictions_found`, or `nothing_to_verify`.

## Events

| Event | Payload highlights |
|-------|--------------------|
| `assayer.audit.started` | `audit_id`, `claim_count`, `command_count`, `trigger` |
| `assayer.claim.contradicted` | `claim`, `claim_type`, `evidence_command`, `result_excerpt`, `confidence` |
| `assayer.claim.unverified` | `claim`, `claim_type`, `reason` |
| `assayer.audit.complete` | `corroborated`, `contradicted`, `unverified`, `verdict`, `duration_ms` |

Corroborated claims are counted in the summary, not emitted individually — the happy path stays quiet.

## Non-goals (v0.1)

- **Blocking.** Assayer is advisory; it never blocks `Stop`. An enforce mode is a future opt-in.
- **Re-running commands.** Assayer reconciles against what already ran; it does not execute anything.
- **Parsing exit codes from output.** It relies on `is_error`. A command that exits 0 while printing failures reads as success.
- **Non-Bash evidence.** Only `Bash` results are treated as evidence today.

## Relationship to other plugins

Assayer occupies the verification/execution layer, empty until now. It is complementary to:

- **tribunal** — judges whether the work is *good*; assayer checks whether the *claims about it* are true.
- **scribe** — writes the narrative of *why*; assayer checks the factual assertions in that narrative's neighbor, the final message.
- **counsel** — can consume `assayer.*` events to surface recurring honesty gaps over time.

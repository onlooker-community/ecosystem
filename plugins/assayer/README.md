# Assayer

Claim verification — does the agent's story match the session's receipts?

When an agent finishes, it tells you what it did: "I ran the tests, they pass," "the build is green," "lint is clean." Assayer treats those as **testable claims** and checks each against what actually happened in the session — the Bash commands that ran and whether they errored. A claim that a passing run contradicts is surfaced, not silently trusted. This catches lying-without-malice: the agent isn't deceiving you, it just misremembered, or assumed, or never re-ran after a change.

Assayer is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

| Hook | What Assayer does |
|------|-------------------|
| `Stop` | Reads the just-finished session's transcript (`transcript_path`). Extracts the agent's testable success claims from its final message with a single `claude -p` pass, cross-checks each against the actual Bash command results in the same transcript, and emits a verdict per claim plus an audit summary. Advisory only — always exits 0, never blocks Stop. |

The pipeline:

```
Stop → Transcript Reader → Claim Extractor (claude -p) → Deterministic Verifier → Events
```

- **Transcript reader** pulls two things from the JSONL transcript: the **final assistant message** (where claims live) and every **Bash command** paired with its result status. Claude Code records a command as a `tool_use` block and its outcome as a `tool_result` carrying an `is_error` flag — there is no per-call numeric exit code, so `is_error` is the success/failure signal.
- **Claim extractor** (LLM) reads only the final message and identifies success claims, tagging each with a `type` (`tests_pass`, `build_succeeds`, `lint_clean`, `types_check`, `command_succeeds`, `generic`) and a `command_keyword` — the substring it expects in the verifying command. The LLM does **not** judge truth; it only identifies claims and what would settle them.
- **Verifier** (deterministic bash) is the factual half: for each claim it finds the most recent command matching the claim's keywords and reads its `is_error`. Same inputs always produce the same verdict.

## Verdicts

| Verdict | Meaning |
|---------|---------|
| **corroborated** | A matching command ran and succeeded. |
| **contradicted** | A matching command ran and **failed** — the claim is not backed by the evidence. |
| **unverified** | No matching command (`no_matching_command`), or the claim implies no checkable command (`ambiguous`). |

The most **recent** matching command wins: an agent may fail, fix, and re-run, and the last run reflects the state the final message describes.

## Activation

Install Assayer from the marketplace:

```
/plugin install assayer@onlooker-community
```

Once installed, the plugin is active — no additional toggle required.

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "assayer": {
    "evaluation": {
      "model": "claude-haiku-4-5-20251001",
      "timeout_seconds": 60
    },
    "max_claims": 12,
    "min_confidence": 0.5,
    "final_message_chars": 6000
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `evaluation.model` | `claude-haiku-4-5-20251001` | Model used for claim extraction. Haiku is fast and cheap; the task is structured and shallow. |
| `evaluation.timeout_seconds` | `60` | Per-pass wall-clock timeout passed to the `timeout` command. |
| `max_claims` | `12` | Maximum number of claims to extract from a final message. |
| `min_confidence` | `0.5` | Claims the extractor scores below this are dropped before verification. |
| `final_message_chars` | `6000` | How many characters of the final assistant message to feed into extraction. |

## Storage layout

```text
~/.onlooker/assayer/<project-key>/
└── audit-<session-id>.json     # advisory summary written at end of each audit
```

Each audit file records the claim count, the corroborated / contradicted / unverified tallies, the overall verdict, and the per-claim list for review in the next session.

Project key: first 12 hex chars of SHA256 of `git remote get-url origin`, falling back to a hash of the repo root realpath — stable across directory moves, clones, and worktrees of the same repo.

## Events emitted

Assayer emits the canonical `assayer.*` event surface from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema). All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

| Event | When |
|-------|------|
| `assayer.audit.started` | Before verification begins. Includes `claim_count` and `command_count`. |
| `assayer.claim.contradicted` | A claim is contradicted by a failing command. Includes the `claim`, the `evidence_command`, and a `result_excerpt`. |
| `assayer.claim.unverified` | A claim has no supporting evidence (`reason`: `no_matching_command` or `ambiguous`). |
| `assayer.audit.complete` | After all claims are checked. Includes the tallies, the `verdict` (`clean`, `contradictions_found`, `nothing_to_verify`), and `duration_ms`. |

Corroborated claims are counted in the summary rather than emitted individually — the happy path is the quiet path.

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- A release of `@onlooker-community/schema` that includes the `assayer.*` event types (the emitter validates every envelope against the installed schema; older versions reject `assayer.*`).
- `claude` CLI on `PATH` (the hook shells out to `claude -p` for the extraction pass).
- `jq` for JSON manipulation.
- `node` for canonical-event emission.
- `python3` for millisecond timestamps (standard on macOS and most Linux distributions).

## Architecture decisions

Key decisions made during initial design are recorded in [`docs/adr/`](docs/adr/):

- [ADR-001](docs/adr/001-verify-claims-against-transcript-evidence.md) — Verify claims at Stop against transcript evidence (and why `is_error`, not exit codes, and why advisory)

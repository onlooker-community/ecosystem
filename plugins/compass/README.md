# Compass

Pre-write intent clarity gate.

Compass fires on `PreToolUse` for write-class operations, evaluates whether the pending write has sufficient intent clarity to proceed, and blocks with a structured clarification prompt when confidence is low or the evaluators disagree. It is the only plugin that gates write-class tool calls before they execute — complementing governor (budget), tribunal (post-task quality), and warden (safety). To avoid the most common false positive — a terse user reply to a question the agent just asked — Compass evaluates the pending write against the **prior assistant turn** as context, not the current context alone. See [ADR-001](docs/adr/001-evaluate-prompts-in-context.md).

Compass is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

| Hook | Surface | What Compass does |
|------|---------|-------------------|
| `PreToolUse` | `Write`, `Edit`, `MultiEdit` | Runs the full evaluation pipeline and blocks the write when confidence is below threshold or the evaluators disagree. |
| `PreToolUse` | `Bash` | Same pipeline, but first matches the command against write patterns (redirects, `rm`, `mv`, `cp`, `tee`, and similar). Exits 0 immediately when no write pattern matches. |
| `PostToolUse` | `Write`, `Edit`, `MultiEdit` | Records the written file path, stem, and timestamp to the session cooldown table so same-file follow-up writes are not re-checked. |
| `SessionStart` | `*` | Initializes session state: zero turn-check count, empty cooldown table, closed circuit breaker. Exits silently when Compass is disabled. |

The evaluation pipeline runs in order:

```
Trigger Gate → Transcript Reader → Symbolic Skip Layer → Sanitizer → N=5 Evaluators → Gate
```

1. **Trigger gate** — applies, in order, the skip sentinel (`[compass:skip]`), skip globs, dir-plus-stem cooldown, the per-turn check budget, the context minimum, and the circuit breaker. The first match short-circuits and emits `compass.check.skipped`.
2. **Transcript reader** — resolves the prior assistant turn from `transcript_path` in the hook JSON payload (the same field `tribunal-stop-gate.sh` reads). Always reads one turn back — already committed before `PreToolUse` fires, so there is no timing-skew risk. When `transcript_path` is absent or unreadable, the pipeline proceeds with an empty prior turn.
3. **Symbolic skip layer** — short-circuits to a pass without an LLM call when the prior turn is an enumerated question and the current context is a clean option reference (a number, an ordinal phrase, or a short affirmation with no qualifier clause). Controlled by `skip_patterns.reply_to_question.enabled` (default `true`).
4. **Sanitizer** — strips evaluator prompt tags, control characters, and null bytes from all evaluator-bound fields, then truncates them, before any content leaves the machine.
5. **N=5 evaluators** — launches `evaluator.n` parallel Haiku calls with a structured prompt that places `<prior_assistant_turn>` and `<context_excerpt>` in separate XML-delimited slots. The convergence question is: *"Given the prior assistant turn as context, would two independent readers converge on the same interpretation of this write?"*
6. **Gate** — aggregates the sample scores into a mean and standard deviation and applies the blocking rule.

### Blocking rule

Compass blocks the write when **`confidence < confidence_threshold` OR `stddev > stddev_threshold`** (defaults `0.65` and `0.20`). The standard-deviation signal is independent of the mean — when the evaluators disagree, that disagreement is itself a reliable ambiguity signal. A blocked write surfaces the triggering file and tool, the mean score, the standard deviation, the most common concern, the evaluator rationale, and three resolution paths: type `compass: proceed` to override, provide more context for a single re-check, or type `compass: cancel` to abandon the write.

### Error handling

The default `error_policy` is `closed`: when fewer than `evaluator.min_valid_samples` return valid JSON, Compass blocks the write and explains that the check could not complete. Set `error_policy: "open"` to pass writes through on evaluator failure (appropriate for CI). A session-scoped circuit breaker opens after `circuit_breaker.consecutive_failures_to_open` consecutive failures and fails open for `circuit_breaker.open_duration_seconds`, regardless of `error_policy`.

## Activation

Compass is **off by default**. Enable per-project in `.claude/settings.json`:

```json
{
  "compass": {
    "enabled": true
  }
}
```

Or globally in `~/.claude/settings.json`.

## Configuration

All keys are optional. Unset keys fall back to the plugin's `config.json` defaults.

```json
{
  "compass": {
    "enabled": false,
    "evaluator": {
      "model": "claude-haiku-4-5-20251001",
      "n": 5,
      "temperature": 0.3,
      "max_output_tokens": 128,
      "sample_timeout_seconds": 8,
      "min_valid_samples": 3
    },
    "confidence_threshold": 0.65,
    "stddev_threshold": 0.2,
    "cooldown": {
      "strategy": "path_and_identity",
      "seconds": 120,
      "identity_match": "dir_plus_stem"
    },
    "transcript": {
      "prior_turn_chars_max": 800
    },
    "skip_patterns": {
      "reply_to_question": {
        "enabled": true
      }
    },
    "max_checks_per_turn": 3,
    "min_context_chars": 80,
    "context_chars_max": 600,
    "include_file_contents": false,
    "skip_globs": ["**/*.lock", "**/*.sum", "**/node_modules/**", "**/.git/**", "**/dist/**", "**/build/**"],
    "error_policy": "closed",
    "circuit_breaker": {
      "enabled": true,
      "consecutive_failures_to_open": 3,
      "open_duration_seconds": 300,
      "open_behavior": "fail_open"
    },
    "intervention": {
      "recheck_limit": 1
    }
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `false` | Must be `true` for any evaluation to run. |
| `evaluator.model` | `claude-haiku-4-5-20251001` | Model used for each evaluation sample. Haiku is fast and cheap; the convergence prompt does not require deep reasoning. |
| `evaluator.n` | `5` | Number of parallel evaluation samples launched per check. |
| `evaluator.temperature` | `0.3` | Sampling temperature. The noise floor at `n=5`, `temperature=0.3` is ~0.62–0.65 for unambiguous tasks, which informs the `confidence_threshold` default. |
| `evaluator.max_output_tokens` | `128` | Token ceiling per sample. The evaluator returns a small JSON object, so this is intentionally tight. |
| `evaluator.sample_timeout_seconds` | `8` | Per-sample watchdog. Samples not returned within this window are killed and excluded. |
| `evaluator.min_valid_samples` | `3` | Minimum number of samples that must return valid JSON. Below this, the `error_policy` is applied. |
| `confidence_threshold` | `0.65` | Mean score below which the write is blocked. Set at the top of the noise floor; raise after running calibration rather than lowering blindly. |
| `stddev_threshold` | `0.2` | Sample standard deviation above which the write is blocked, independent of the mean. |
| `cooldown.seconds` | `120` | A write whose path shares a parent directory and filename stem with a recent successful write is skipped within this window. |
| `cooldown.identity_match` | `dir_plus_stem` | Cooldown identity strategy. Stem comparison strips only the final extension; the cooldown does not carry across a rename. |
| `transcript.prior_turn_chars_max` | `800` | Maximum characters of the prior assistant turn fed into the evaluator. Set to `0` to omit the prior turn for near-zero egress. |
| `skip_patterns.reply_to_question.enabled` | `true` | Enables the symbolic skip layer. When disabled, every write that passes the trigger gate reaches the LLM evaluator. |
| `max_checks_per_turn` | `3` | Per-turn evaluation budget. Writes beyond this skip with reason `turn_budget_exhausted`. |
| `min_context_chars` | `80` | Minimum sanitized context length. Shorter context skips with reason `insufficient_context`. |
| `context_chars_max` | `600` | Maximum characters of context sent to the evaluator. Set to `0` for near-zero egress. |
| `include_file_contents` | `false` | When `false`, file contents are never sent to the evaluator — only tool name, file path, operation type, prior turn excerpt, and context excerpt. |
| `skip_globs` | lock/sum/`node_modules`/`.git`/`dist`/`build` patterns | Paths matching any glob skip evaluation entirely. |
| `error_policy` | `"closed"` | `closed` blocks on evaluator failure; `open` passes the write through and emits `compass.check.skipped` with reason `sampler_error`. |
| `circuit_breaker.enabled` | `true` | Enables the session-scoped circuit breaker. |
| `circuit_breaker.consecutive_failures_to_open` | `3` | Consecutive evaluator failures before the circuit opens. |
| `circuit_breaker.open_duration_seconds` | `300` | How long the circuit stays open (failing open) before attempting to close. While open, writes skip with reason `circuit_open`. |
| `intervention.recheck_limit` | `1` | Maximum re-checks per intervention after a user supplies clarification. |

The plugin's `config.json` is the source of truth for available knobs.

### Data egress

Every evaluation sends content to the `evaluator.model` API endpoint. With `include_file_contents: false` (the default), Compass sends only the tool name, file path, operation type, bash command string (command only, not stdin), the prior assistant turn excerpt, and the context excerpt — never file contents. For near-zero egress, set `context_chars_max: 0` and `transcript.prior_turn_chars_max: 0`. Compass cannot auto-detect sensitive paths; for sensitive repositories, set `enabled: false`.

## Storage layout

Compass keeps per-session state — the turn-check count, cooldown table, and circuit-breaker state — under the shared substrate:

```text
~/.onlooker/compass/sessions/
└── <session-id>.json   # turn_check_count, cooldown[], circuit_breaker{state, consecutive_failures, opened_at}
```

State is keyed by session ID and initialized at `SessionStart`. The runtime root is always resolved via `${ONLOOKER_DIR:-$HOME/.onlooker}` so the test suite's isolated temp home is respected.

## Events emitted

Compass emits the canonical `compass.*` event surface from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema). All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

| Event | When | Key payload fields |
|-------|------|--------------------|
| `compass.check.passed` | Confidence ≥ threshold and stddev ≤ threshold. | `confidence`, `stddev`, `file_path`, `tool_name`, `had_prior_turn` |
| `compass.check.failed` | Confidence < threshold or stddev > threshold. | `confidence`, `stddev`, `primary_concern`, `file_path` |
| `compass.check.skipped` | A gate rule or the symbolic skip layer matched. | `reason`, `file_path` |

`compass.check.skipped` reasons: `skip_sentinel`, `skip_glob`, `dir_plus_stem_cooldown`, `turn_budget_exhausted`, `insufficient_context`, `circuit_open`, `reply_to_question_pattern`, and `sampler_error`.

## Requirements

- The `ecosystem` plugin installed (for the `~/.onlooker/` substrate and canonical event emission).
- `claude` CLI on `PATH` (the evaluator shells out to `claude -p` for each sample).
- `jq` for JSON manipulation.
- `node` for canonical-event emission.

## Architecture decisions

Key decisions made during design are recorded in [`docs/adr/`](docs/adr/):

- [ADR-001](docs/adr/001-evaluate-prompts-in-context.md) — Evaluate prompts in context (with the prior assistant turn), not in isolation, plus the symbolic skip pattern for question-answer turns

The full design, including failure modes, the intervention UX, integration points, and open questions, lives in [`docs/design.md`](docs/design.md).

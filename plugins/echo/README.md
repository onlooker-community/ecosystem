# Echo

A measurement harness for LLM-as-judge evaluation of prompt-shaped files.

**Echo ships no hooks.** It had one — a Stop hook that scored changed agent, command and skill files and compared each score against a stored baseline to report `improved` / `degraded` / `neutral`. That hook was retired in [ONL-103](https://linear.app/onlooker/issue/ONL-103) because it was measured, twice, and does not work. What remains is the instrument that measured it, which is worth keeping.

## Why the runtime was retired

Two measurements, both with pre-registered criteria and committed raw artifacts:

**[ADR-004](docs/adr/004-drift-threshold-from-measured-spread.md) / ONL-102** — 86 judge calls over six files. Between-document signal sd was **0.048**; re-scoring one document moved it **0.079**. Signal/noise **0.61**. The rubric could not reliably tell two *different* documents apart, and echo's actual job — telling two *versions of one* document apart — is strictly harder. Setting `drift_threshold` to the honest measured value (0.28) made echo truthful without making it useful.

**[ADR-005](docs/adr/005-retire-the-stop-gate.md) / ONL-103** — 72 judge calls testing whether pairwise comparison rescued it. It did not. Identity recognition was perfect (`self_tie_rate` 12/12) and position bias was negligible (3.3%), but **40% of ordered pairs returned a different verdict across two identical repeats**. Pairwise removed the absolute scale and the instability survived it.

Production confirmed the consequence. In the ten days after `drift_threshold` became 0.28, the hook fired roughly **1,100 times and emitted zero** improvement or regression events. All nine verdicts it ever produced came from the earlier 0.05 era, and the largest |delta| it ever observed was 0.24 — below the honest threshold, so none of them would fire today.

The reading that closed it: the judge is **reliable on determinate questions and unreliable on indeterminate ones**. "Is version B of this skill file better than version A" often has no determinate answer, so a larger model does not fix it. Whether a *determinate* version of the check is worth building is [ONL-133](https://linear.app/onlooker/issue/ONL-133); where this harness should ultimately live is [ONL-134](https://linear.app/onlooker/issue/ONL-134).

## What the harness does

It answers one question about any LLM judge: **does it discriminate between different inputs more reliably than it reproduces itself on identical input?** A judge that fails this cannot support a before/after comparison, however the comparison is framed.

```bash
# Absolute scoring: spread of |delta| between independent evaluations of
# identical content, for single-sample, median-of-3 and median-of-5.
plugins/echo/scripts/measure-judge-spread.sh --dry-run   # show the plan, spend nothing
plugins/echo/scripts/measure-judge-spread.sh             # 10 samples x 3 files = 30 calls

# Pairwise: self-tie rate, cross antisymmetry, position bias, and whether a
# verdict reproduces across repeats.
plugins/echo/scripts/measure-pairwise-discrimination.sh --dry-run
plugins/echo/scripts/measure-pairwise-discrimination.sh --repeats 2 --out <dir> <files...>
```

Each run writes raw per-call results alongside computed statistics, and stamps the **model** and a **prompt fingerprint** into the output. That stamping is the point: ADR-004 exists because an earlier figure carried no methodology and so could neither be defended nor re-derived. A result that does not name its prompt and model describes nothing.

Neither runner is part of `npm test` — a suite costing 30–72 judge calls is one nobody runs. Plumbing is covered against a stubbed `claude` in `test/bats/echo-measure-judge-spread.bats` and `test/bats/echo-measure-pairwise.bats`; the arithmetic is covered exhaustively in `test/node/judge-spread-stats.test.mjs` and `test/node/pairwise-stats.test.mjs`.

### Committed results

`docs/measurements/2026-10-03-pairwise/` holds the full ONL-103 run — every per-pair verdict plus the computed statistics. It is committed rather than left in scratch because `cross_antisymmetry` counts a tie-against-a-preference as a failure, which is a **pre-registered choice, not a fact**: counting only self-contradictory verdicts gives 96.7% instead of 56.7% and flips the verdict. Anyone arguing the result under a different definition needs the per-pair data, and re-deriving it costs 72 judge calls.

## Configuration

Both keys are optional and fall back to `config.json`.

```json
{
  "echo": {
    "evaluation": {
      "model": "claude-haiku-4-5-20251001",
      "timeout_seconds": 60
    }
  }
}
```

| Key | Default | Description |
|-----|---------|-------------|
| `evaluation.model` | `claude-haiku-4-5-20251001` | Judge model. Every measurement is a property of this value, so changing it invalidates comparison against prior runs — which is why it is stamped into the output rather than assumed. |
| `evaluation.timeout_seconds` | `60` | Per-call wall-clock timeout passed to `timeout`. |

`watch_paths`, `exclude_paths` and `drift_threshold` were read only by the retired hook and are gone. A `drift_threshold` left in your settings is inert, not respected.

## Scoring rubric

What the absolute-scoring judge is asked for — 0.0–1.0 on four equally weighted criteria:

| Criterion | What it checks |
|-----------|---------------|
| **Role clarity** | Does the file clearly define what the agent is and what it must do? |
| **Output format** | Are output format and schema requirements unambiguous? |
| **Criterion coverage** | Are all evaluation dimensions specified with enough detail to apply consistently? |
| **Internal consistency** | No contradictory instructions; no undefined terms. |

ONL-102 measured these as unanchored — scored 0.0–1.0 with no level descriptors, which invites the model to land anywhere in a broad band. The prompt lives in [`scripts/lib/echo-judge-prompt.sh`](scripts/lib/echo-judge-prompt.sh), shared by both runners so a measurement and the thing it measures cannot drift apart.

## Events

**Echo emits nothing.** The `echo.*` types remain registered in [`@onlooker-community/schema`](https://github.com/onlooker-community/schema) so the committed measurement artifacts stay interpretable, and they are listed as `excluded` in `test/bus-coverage.json` with that reason. `scripts/lint/check-plugin-liveness.mjs` reports echo as `no_runtime` — an answer, not a finding.

## Leftover storage

Baselines written by the retired hook may still exist:

```text
~/.onlooker/echo/<project-key>/
├── baselines/<test-id>.json
└── run-<session-id>.json
```

Nothing reads them. They are harmless and left in place rather than deleted, since removing data on a plugin upgrade is not this change's call to make.

## Requirements

- `claude` CLI on `PATH` — both runners shell out to `claude -p`.
- `jq` for JSON manipulation.
- `node` for the statistics modules.

The `ecosystem` substrate is no longer required: with no events to emit, echo does not need `~/.onlooker/`.

## Architecture decisions

- [ADR-001](docs/adr/001-echo-as-separate-plugin.md) — Echo as a separate plugin, not an extension of Tribunal
- [ADR-002](docs/adr/002-direct-evaluation-vs-tribunal-pipeline.md) — Direct `claude -p` evaluation vs. routing through Tribunal's full pipeline
- [ADR-003](docs/adr/003-stop-hook-trigger.md) — Stop hook as the trigger mechanism *(superseded by ADR-005)*
- [ADR-004](docs/adr/004-drift-threshold-from-measured-spread.md) — `drift_threshold` from a measured spread, not a chosen number
- [ADR-005](docs/adr/005-retire-the-stop-gate.md) — Retire the stop gate; keep the harness

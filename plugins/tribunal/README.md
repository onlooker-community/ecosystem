# Tribunal

Multi-agent execution with LLM-as-a-Judge quality gates.

Tribunal wraps a task in a three-tier evaluation loop:

1. An **Actor** subagent performs the work.
2. A **jury** of typed **Judges** scores the output against a rubric.
3. A **Meta-Judge** reviews the jury for bias, hallucination, and criteria misapplication.
4. A configurable **gate policy** decides whether to accept, retry, or give up.

Grounded in two papers:

- [LLM-as-a-Judge (Zheng et al. 2023)](https://arxiv.org/abs/2306.05685) — strong LLMs can score other LLMs against rubrics with reasonable agreement to human judgment.
- [LLM-as-a-Meta-Judge (Wu et al. 2024)](https://arxiv.org/abs/2407.19594) — a second model reviewing the Judge catches position, verbosity, and self-enhancement bias.

Tribunal is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker observability substrate (`~/.onlooker/`) is present.

## How it works

| Surface | What tribunal does |
|---|---|
| `/tribunal <task>` skill | Orchestrates a full Actor → Jury → Meta → Gate loop, retrying the Actor with Judge critiques until the gate passes or `max_iterations` is reached. Emits the full canonical event stream. |
| `Stop` hook (opt-in) | When `tribunal.stop_hook.enabled` is true, runs a single advisory pass on the just-finished turn's output and writes a verdict for review on the next session. No retry — the main session has already ended. |

## Default jury

Out of the box, Tribunal empanels **two judges** to showcase the jury model without the cost of a full panel:

- `tribunal-judge-standard` — correctness, completeness, clarity.
- `tribunal-judge-adversarial` — devil's advocate, actively looks for failure modes and unhandled edges.

The gate uses `majority` policy with `weighted_mean` aggregation, so one strong reject does not automatically block. `tribunal-judge-security` is shipped but off by default — opt in for security-sensitive repos by adding `"security"` to `judge_types`.

## Configuration

Tribunal is enabled by default; the Stop hook is opt-in. Override per-project in your project's `.claude/settings.json`:

```json
{
  "tribunal": {
    "session": {
      "judge_types": ["standard", "security", "adversarial"],
      "gate_policy": "majority",
      "max_iterations": 5
    },
    "stop_hook": { "enabled": true }
  }
}
```

The full default `config.json` is the source of truth for available knobs.

### Project rubric override

Drop a `rubrics` file at `<repo>/.claude/tribunal.json` (or globally at `~/.onlooker/tribunal.json`) to override the built-in `default` rubric or add named rubrics referenced as `/tribunal --rubric=<id>`:

```json
{
  "rubrics": [
    {
      "id": "default",
      "criteria": [
        { "name": "correctness", "weight": 0.5, "min_pass": 0.8 },
        { "name": "tests",       "weight": 0.3, "min_pass": 0.7 },
        { "name": "docs",        "weight": 0.2, "min_pass": 0.5 }
      ],
      "score_threshold": 0.8,
      "max_iterations": 5,
      "judge_types": ["standard", "security", "adversarial"],
      "gate_policy": "majority",
      "aggregation_method": "weighted_mean"
    }
  ]
}
```

Project rubrics override built-ins by `id`.

## Subagents

| Agent | `judge_type` | Role |
|---|---|---|
| `tribunal-actor` | n/a | Performs the task. Receives prior iteration's verdicts on retries. |
| `tribunal-judge-standard` | `standard` | General correctness, completeness, clarity. |
| `tribunal-judge-security` | `security` | Vulnerability-focused: injection, auth bypass, data exposure. |
| `tribunal-judge-adversarial` | `adversarial` | Actively tries to find failure modes and missing edge cases. |
| `tribunal-meta-judge` | `meta` | Reviews each Judge's verdict for the six bias types defined in the LLM-as-a-Judge paper. |

`maintainability` and `domain` judge types are recognized in config but not yet shipped as subagents; they degrade to `standard` with a warning. They are planned for v0.2.

## Storage layout

```text
~/.onlooker/tribunal/<project-key>/
├── manifest.json
└── <task_id>/                          # ULID
    ├── manifest.json
    ├── session-start.json
    ├── session-complete.json
    └── iteration-<iteration_id>/       # ULID per iteration
        ├── actor.md
        ├── jury.json
        ├── verdicts/
        │   └── <judge_id>.json         # one per judge
        ├── consensus.json
        ├── dissent.json                # only when emitted
        ├── meta.json
        └── gate.json
```

Project keying mirrors `archivist`: SHA256 of `git remote get-url origin` (first 12 hex), falling back to a hash of the repo root realpath. Worktrees of the same repo share a key.

## Events emitted

Tribunal emits the full canonical `tribunal.*` event surface from [`@onlooker-community/schema`](https://github.com/onlooker-community/schema) (v2.1.0+):

`session.start`, `iteration.start`, `actor.start`, `actor.complete`, `jury.empaneled`, `judge.start`, `verdict` (one per judge), `meta.start`, `meta.complete`, `consensus.reached`, `dissent.recorded` (when judges disagree), `gate.passed` / `gate.blocked`, `session.complete`.

All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `claude` CLI on `PATH` (the Stop hook shells out to `claude -p` for its advisory pass).
- `jq` for JSON manipulation.
- `node` for canonical-event emission (the ecosystem plugin already requires this).

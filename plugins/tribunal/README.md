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
| `/tribunal <task>` skill | Orchestrates a full Actor → Jury → Meta → Gate loop, retrying the Actor with Judge critiques until the gate passes or `max_iterations` is reached. Emits the full canonical event stream. When a run ends rejected or out of iterations, it asks whether to keep the changes, discard them, or retry, and records the answer as `tribunal.session.resolved`. Discard restores only the files that were clean when the run started. It works from `git status`, so it leaves git-ignored files alone: build output and caches the run wrote stay, and so does a `.env`. |
| `Stop` hook (opt-in) | When `tribunal.stop_hook.enabled` is true, runs a single advisory pass on the just-finished turn's output and writes a verdict for review on the next session. No retry — the main session has already ended. The judge sees only the files this session's transcript shows it editing (Edit, Write, MultiEdit, NotebookEdit) that are still uncommitted, never another session's work in the same checkout; with `skip_if_no_file_changes` (default true), a session with none spends no model call. A file changed only through Bash is not attributed. |
| `Stop` nudge (on by default) | Makes no model call. When a session's edits are numerous or touch a sensitive path, shows one line suggesting `/tribunal`. See [Nudge](#nudge). |

## Default jury

Out of the box, Tribunal empanels **two judges** to showcase the jury model without the cost of a full panel:

- `tribunal-judge-standard` — correctness, completeness, clarity.
- `tribunal-judge-adversarial` — devil's advocate, actively looks for failure modes and unhandled edges.

The gate uses `majority` policy with `weighted_mean` aggregation, so one strong reject does not automatically block. `tribunal-judge-security` is shipped but off by default — opt in for security-sensitive repos by adding `"security"` to `judge_types`.

## Configuration

Install the plugin in Claude from the marketplace with:

```
/plugin install tribunal@onlooker-community
```

The Stop hook is opt-in. Override per-project in your project's `.claude/settings.json`:

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

## Nudge

The jury costs several model calls, so tribunal never runs it unasked. The nudge is the free half: a `Stop` hook that makes no model call and, when the session's edits look like they deserve a jury, shows you one line:

```text
tribunal: this session changed 9 files, 1 sensitive (db/migrations/004.sql). Worth a jury? /tribunal runs several judge models; type it to start.
```

It is on by default. It stays quiet when the paid Stop gate (`stop_hook.enabled`) is on, and once `/tribunal` has run in the session.

It counts the files this session's transcript shows it editing (Edit, Write, MultiEdit, NotebookEdit) inside the worktree, committed or not, after dropping `ignore_globs`. Two triggers:

- **size**: the count reaches `min_files`.
- **sensitive**: any file matches `sensitive_globs`. Matching is case-insensitive.

It speaks once. After that it speaks again only when the session grows: a sensitive path appears that it has not named yet, or the count is past `min_files` and at least double what it last reported.

| Key (`tribunal.nudge.*`) | Default | |
|---|---|---|
| `enabled` | `true` | `false` turns it off with no cost beyond reading config. |
| `min_files` | `8` | `0` turns the size trigger off. A value that is not a non-negative integer reads as `8`. |
| `sensitive_globs` | `.github/workflows/**`, `**/migrations/**`, `**/auth/**`, `**/*secret*`, `**/*credential*`, `**/.env*` | `*` stays within one directory; `**/` matches zero or more directories. |
| `ignore_globs` | `**/*.lock`, `**/package-lock.json`, `**/pnpm-lock.yaml`, `**/yarn.lock` | Dropped before counting. |

A list you set **replaces** the default; it is not merged with it. To add a pattern, repeat the defaults you want to keep. In `.claude/settings.json`:

```json
{
  "tribunal": {
    "nudge": {
      "sensitive_globs": [
        "plugins/*/scripts/hooks/*.sh",
        ".github/workflows/**",
        "**/migrations/**",
        "**/auth/**",
        "**/*secret*",
        "**/*credential*",
        "**/.env*"
      ]
    }
  }
}
```

The onlooker CLI (2.14.0 and later) writes the same file: `onlooker config set tribunal.nudge.min_files 5 --scope project`.

Events: `tribunal.nudge.shown` with `trigger` (`size`, `sensitive` or `grew`), `session_files` and up to 20 `sensitive_files`; `tribunal.nudge.skipped` with a `reason`, emitted once per session per reason. Turning the nudge off emits nothing.

Limitations:

- Files changed only through Bash (`sed -i`, `mv`, codegen) are not counted; the transcript does not record them as edits.
- The count is of files, not lines. Eight one-line edits trip the size trigger, while one 2000-line rewrite does not.

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
    ├── baseline.json                   # files already dirty when the run started
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

`session.start`, `iteration.start`, `actor.start`, `actor.complete`, `jury.empaneled`, `judge.start`, `verdict` (one per judge), `meta.start`, `meta.complete`, `consensus.reached`, `dissent.recorded` (when judges disagree), `gate.passed` / `gate.blocked`, `session.complete`, `session.resolved` (schema v3.11.0+, after a rejected or exhausted run), and the nudge's `nudge.shown` / `nudge.skipped` (schema v3.10.0+).

All events land in `~/.onlooker/logs/onlooker-events.jsonl` and are validated against the schema before write.

## Requirements

- The `ecosystem` plugin installed (for `~/.onlooker/` substrate).
- `claude` CLI on `PATH` (the Stop hook shells out to `claude -p` for its advisory pass).
- `jq` for JSON manipulation.
- `node` for canonical-event emission (the ecosystem plugin already requires this).

## Architecture decisions

Key decisions made during initial design are recorded in [`docs/adr/`](docs/adr/):

- [ADR-001](docs/adr/001-actor-jury-meta-gate-loop.md) — The Actor → Jury → Meta-Judge → Gate loop
- [ADR-002](docs/adr/002-majority-gate-policy.md) — Majority gate policy as default (and the 2-judge edge case)

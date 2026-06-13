# Inspector

Per-edit lint and typecheck gate for the Onlooker ecosystem — runs the project's
configured checks on **just the touched file** after every `Write`, `Edit`, and
`MultiEdit`, so the agent sees its own lint and type errors before it claims
success.

Inspector is a sibling plugin to [`ecosystem`](../../) and assumes the Onlooker
observability substrate (`~/.onlooker/`) is present.

## Why it exists

The ecosystem already has plugins that judge agent output after the fact and
plugins that gate ambiguous writes before they happen. What it didn't have until
now is a fast feedback loop that runs after every edit and tells the agent
*whether the code it just wrote actually compiles*. Inspector is that loop.

- **Not [proctor]** (planned) — proctor runs the project's full verification
  command at `Stop`. Inspector runs only on touched files, only on `PostToolUse`.
  Cheaper, fires far more often, narrower scope.
- **Not [assayer]** — assayer parses the agent's final message for testable
  claims and cross-checks them against actual exit codes in the transcript.
  Assayer catches the agent *lying* about claims. Inspector ensures the agent
  has *accurate ground truth* to make claims from. They compose: inspector
  emits real pass/fail signals; assayer can later confirm the agent's claims
  line up with those signals.
- **Not a build system** — inspector runs the configured command, captures the
  result, emits an event, exits. No cross-file caching, no dependency graphs.

## How it works

| Hook | Matcher | What Inspector does |
|------|---------|---------------------|
| `PostToolUse` | `Edit`, `Write`, `MultiEdit` | Resolves the touched file from `tool_input.file_path`, looks up the configured checks for the file's extension, runs each check with a per-check timeout, and emits `inspector.check.passed` / `.failed` / `.skipped` plus a single `inspector.run.completed` summary. Bounded by `total_timeout_seconds`. Always exits 0 — inspector is advisory and never blocks the tool call. |

The hook's stdout (the additional-context channel for `PostToolUse` hooks) is
the agent-facing summary. By default it's quiet on clean runs:

```
inspector: src/cart.ts
  ✗ biome (3 issues, exit 1)
      src/cart.ts:42:5 — Unused variable 'subtotal'
      src/cart.ts:51:3 — Missing return type annotation
      src/cart.ts:64:9 — Unreachable code
  ✗ tsc (1 issue(s), exit 2)
      src/cart.ts:42:5 — Type 'string | undefined' is not assignable to 'string'
```

Set `inspector.show_clean_runs: true` to surface the file header on passing
checks too. The agent sees this on its next turn.

## Activation

Inspector ships disabled. Opt in per project (or globally) by adding the
`inspector` block to `.claude/settings.json`:

```jsonc
{
  "inspector": {
    "enabled": true,
    "checks": {
      ".ts":  [{ "name": "biome",      "kind": "lint",      "argv": ["biome", "check", "${file}"] },
               { "name": "tsc",        "kind": "typecheck", "argv": ["tsc",   "--noEmit"] }],
      ".tsx": [{ "name": "biome",      "kind": "lint",      "argv": ["biome", "check", "${file}"] },
               { "name": "tsc",        "kind": "typecheck", "argv": ["tsc",   "--noEmit"] }],
      ".py":  [{ "name": "ruff",       "kind": "lint",      "argv": ["ruff",  "check", "${file}"] }],
      ".sh":  [{ "name": "shellcheck", "kind": "lint",      "argv": ["shellcheck", "${file}"] }]
    }
  }
}
```

Each check is an `{ name, kind, argv }` object. `kind` is one of `lint` or
`typecheck` (used for downstream grouping). `argv` is the literal argv array;
the following placeholders are expanded before exec:

| Placeholder       | Resolves to                                |
|-------------------|--------------------------------------------|
| `${file}`         | absolute path to the touched file          |
| `${file_relative}`| path relative to the repo root             |
| `${repo_root}`    | the repo's `git rev-parse --show-toplevel` |

A bare argv array (`["shellcheck", "${file}"]`) is also accepted as a shorthand
— inspector treats the first entry as the check name and the kind as `lint`.

## Config

| Field | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Master switch. |
| `timeout_seconds_per_check` | `10` | Wall-clock cap per check. Exceeded → `inspector.check.skipped` with `reason: "timeout"`. |
| `total_timeout_seconds` | `30` | Wall-clock cap for the whole run. Remaining checks emit `.skipped` with `reason: "total_budget_exhausted"`. |
| `output_excerpt_max_bytes` | `4096` | Cap on captured output, both in the event and shown to the agent. Excess is replaced with `…[truncated]`. |
| `show_clean_runs` | `false` | If `true`, the agent-facing summary includes passing checks too. Off by default to keep token usage low. |
| `exclude_paths` | `["node_modules", ".git", "vendor", ".venv", "dist", ".next", ".nuxt", "build", "__pycache__", "target", "coverage"]` | Containment match against the file's path relative to the repo root. A match emits `inspector.check.skipped` with `reason: "excluded_path"` and runs no checks. |
| `checks` | `{}` | Map of file extension (with leading dot) to an array of check definitions. Empty by default — opt in per project. |

Config precedence: plugin defaults < `~/.claude/settings.json` (`.inspector`) <
`<repo>/.claude/settings.json` (`.inspector`). Each layer fully replaces the
`checks` array for a given extension; per-entry deep-merge is intentionally not
supported because the override behavior would be unpredictable.

## Events

All events are registered in `@onlooker-community/schema`.

| Event | When | Notable payload fields |
|---|---|---|
| `inspector.check.passed` | A check returned exit 0 | `file_path`, `tool_name`, `check_name`, `check_kind`, `argv`, `duration_ms` |
| `inspector.check.failed` | A check returned non-zero | `exit_code`, `issue_count` (best-effort, may be `null`), `output_excerpt`, `output_truncated` |
| `inspector.check.skipped` | A check or whole file was not run | `reason`: one of `disabled`, `excluded_path`, `no_extension_match`, `not_in_repo`, `tool_missing`, `timeout`, `total_budget_exhausted` |
| `inspector.run.completed` | Once per hook fire after all checks | `checks_run`, `checks_passed`, `checks_failed`, `checks_skipped`, `duration_ms` |

Downstream consumers that just want "did this edit produce broken code?" read
`inspector.run.completed` and check `checks_failed > 0`. Consumers that want
per-tool detail subscribe to `inspector.check.*`.

## Whole-project checks (tsc, mypy, …)

TypeScript's typecheck is project-scoped: `tsc --noEmit` checks every file, not
just the touched one. There is no meaningful "tsc on one file." The supported
pattern is to run the full project tsc and rely on its incremental cache
(`tsBuildInfoFile`) to keep latency down. Same applies to mypy, cargo check,
and golangci-lint.

The downside is that `tsc --noEmit` reports errors in *every* file. Inspector's
v1 surfaces all of them to the agent. A follow-up will add an opt-in filter
that shows only errors mentioning the touched file plus a collateral-error
count.

## Failure modes

Inspector is advisory — it never blocks the tool call. Specifically:

- Missing tool on PATH → `.skipped` event, no agent-facing output
- Timeout → `.skipped` event, one-line note to the agent
- Hook script error → exit 0 with no event (last-resort path)
- Schema validation error → logged to stderr, hook continues

## Compatibility

- bash 3.2+ (the macOS system bash is supported; no `mapfile` / `readarray` /
  associative arrays)
- `jq` is required (already a hard requirement for the ecosystem substrate)
- `timeout` from coreutils is used when present; falls back to no-timeout mode
  when absent (and emits a warning to the inspector hook log)

## Design

See [`docs/design.md`](docs/design.md) for the full design record, including
the rationale for project-wide check semantics, output filtering, and open
questions.

[proctor]: https://github.com/onlooker-community/ecosystem#planned
[assayer]: ../assayer

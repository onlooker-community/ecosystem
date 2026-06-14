# Inspector — Design

**Layer:** verification / execution
**Hook surface:** `PostToolUse` for `Write`, `Edit`, `MultiEdit`
**Status:** initial design — first implementation under this doc

Inspector is the per-edit lint and typecheck gate. Every time the agent writes
to a file, inspector runs the project's configured checks on **just that file**
and surfaces the result back to the agent before its next turn. The agent sees
its own type errors immediately and self-corrects, instead of claiming success
on broken code and getting caught later by [assayer] or a human reviewer.

## What inspector is — and isn't

- **Inspector is not proctor.** Proctor (planned) runs the project's full
  verification command (`npm test`, `mise run check`, …) at `Stop`. Inspector
  runs only on touched files, only on `PostToolUse`. Cheaper, fires far more
  often, narrower scope.
- **Inspector is not assayer.** Assayer (shipped) parses the agent's final
  message for testable claims ("the build passes", "I ran the tests") and
  cross-checks them against actual exit codes in the transcript. Assayer catches
  the agent *lying* about claims. Inspector ensures the agent has *accurate
  ground truth* to make claims from. They compose: inspector emits real
  pass/fail signals; assayer can later confirm the agent's claims line up with
  those signals.
- **Inspector is not a build system.** It does not chain dependencies, cache
  intermediate results, or share state across invocations beyond timeouts. It
  runs the configured check, captures the result, emits an event, exits. If
  configuration says "run tsc on a single file," it does that — even though
  tsc's per-file mode loses project context. Choosing the right command for a
  given language is the user's job; inspector executes what it is told.

## Hook flow

```
PostToolUse(Write|Edit|MultiEdit)
  → inspector-post-write.sh
    → resolve touched file from tool_input.file_path
    → load merged config (plugin defaults < home < repo)
    → if disabled OR excluded path OR no extension match → emit .skipped, exit 0
    → for each configured check matching the extension:
        → expand ${file}, ${file_relative}, ${repo_root} in the command
        → run with per-check timeout
        → emit inspector.check.passed / .failed / .skipped
    → exit 0 (never blocks the tool call)
```

The hook always exits 0. Inspector is advisory — it never blocks the agent's
write. It surfaces what it found in the additional-context channel of the
PostToolUse hook reply so the agent sees the result on its next turn.

## Configuration

The minimum useful configuration is a map from file extension to a list of
commands to run. Each command is an argv array; `${file}` substitutes the
canonical absolute path to the touched file.

```jsonc
{
  "inspector": {
    "enabled": false,
    "timeout_seconds_per_check": 10,
    "total_timeout_seconds": 30,
    "exclude_paths": ["node_modules", ".git", "vendor", "dist", "build",
                       ".next", "__pycache__", ".venv"],
    "checks": {
      ".ts":  [{ "name": "biome",      "argv": ["biome", "check", "${file}"] },
               { "name": "tsc",        "argv": ["tsc",   "--noEmit"] }],
      ".tsx": [{ "name": "biome",      "argv": ["biome", "check", "${file}"] },
               { "name": "tsc",        "argv": ["tsc",   "--noEmit"] }],
      ".py":  [{ "name": "ruff",       "argv": ["ruff",  "check", "${file}"] }],
      ".sh":  [{ "name": "shellcheck", "argv": ["shellcheck", "${file}"] }]
    }
  }
}
```

Merging follows the standard ecosystem precedence (plugin defaults < home <
repo). Each layer can fully replace `checks` for a given extension by setting
the array; deep-merge of individual entries within an extension is intentionally
not supported — it makes the override behavior unpredictable.

`config.json` ships with `enabled: false` to match the rest of the ecosystem.
The first PR that ships inspector also adds an opt-in path in the README.

## Path handling

- `file_path` is resolved via `realpath` where available, falling back to
  `readlink -f`, falling back to the raw input.
- The file must be inside the current repo root (`git rev-parse --show-toplevel`
  from `cwd`). Out-of-tree writes are skipped — inspector is per-project.
- `exclude_paths` is matched against the file's path relative to the repo root.
  Match semantics are *containment* (`vendor/foo.ts` matches `vendor`), not
  glob. Compass uses globs; inspector uses containment because the use case is
  "skip this whole directory tree."

## Per-check execution

Each check runs in the repo root (`cwd`) with the following environment:

- inherited PATH plus any `mise`-shimmed bins (already set up at session start)
- `INSPECTOR_FILE` — absolute path to the touched file
- `INSPECTOR_FILE_RELATIVE` — relative to repo root
- `INSPECTOR_REPO_ROOT` — the repo root
- `INSPECTOR_PROJECT_KEY` — the project key

`timeout_seconds_per_check` is enforced via the `timeout` command (or a
fallback bash trap on systems that lack it). On timeout, inspector emits
`inspector.check.skipped` with `reason: "timeout"`.

If the command's first argv entry is not on PATH, inspector emits
`inspector.check.skipped` with `reason: "tool_missing"`. This is the dominant
"new project, lint not installed yet" case and must be quiet — no error in the
hook output, just the skipped event in the log.

## What the agent sees

The hook's stdout (the additional-context channel for PostToolUse hooks)
contains a compact, one-line-per-finding summary:

```
inspector: src/cart.ts
  ✗ biome (3 issues)
      src/cart.ts:42:5 — Unused variable 'subtotal'
      src/cart.ts:51:3 — Missing return type annotation
      src/cart.ts:64:9 — Unreachable code
  ✗ tsc (1 error)
      src/cart.ts:42:5 — Type 'string | undefined' is not assignable to 'string'
```

On clean runs, inspector either emits nothing to stdout (the silent case) or a
single confirmation line, controlled by `inspector.show_clean_runs`
(default `false`). Default silence avoids token spam on every edit.

Output capture per check is bounded by `inspector.output_excerpt_max_bytes`
(default 4096) — beyond that, inspector truncates with a `…[truncated]` marker
both in the agent-facing output and in the event payload.

## tsc and other whole-project checks

TypeScript's typecheck is project-scoped: `tsc --noEmit` checks every file in
the project, not just the touched one. Inspector cannot meaningfully run "tsc
on a single file" — `tsc --noEmit src/foo.ts` runs in a degraded mode that
loses project context (imports, references, lib types).

The right behavior is to run `tsc --noEmit -p tsconfig.json` (full project)
and filter the output to errors that mention the touched file. The first
implementation runs the full project tsc and post-filters. This is more
expensive than the lint case but cached by tsc's incremental compilation
(`tsBuildInfoFile`). Users who care about latency can disable the tsc check
per-project.

Other languages with similar whole-project semantics (mypy, cargo check,
golangci-lint) follow the same pattern: run the project-wide command, filter
results to the touched file. Users opt into these in `config.json` because the
cost is higher than per-file lint.

## Events

All four events are registered in `@onlooker-community/schema` under
`plugins-verification.json`.

### `inspector.check.passed`

Emitted once per check that passed cleanly.

```jsonc
{
  "file_path": "/abs/path/to/src/cart.ts",
  "file_path_relative": "src/cart.ts",
  "tool_name": "Edit",            // Write | Edit | MultiEdit
  "check_name": "biome",
  "check_kind": "lint",           // lint | typecheck
  "argv": ["biome", "check", "/abs/path/to/src/cart.ts"],
  "duration_ms": 124
}
```

### `inspector.check.failed`

Emitted once per check that returned a non-zero exit code.

```jsonc
{
  "file_path": "/abs/path/to/src/cart.ts",
  "file_path_relative": "src/cart.ts",
  "tool_name": "Edit",
  "check_name": "tsc",
  "check_kind": "typecheck",
  "argv": ["tsc", "--noEmit"],
  "duration_ms": 980,
  "exit_code": 2,
  "issue_count": 3,
  "output_excerpt": "src/cart.ts:42:5 — Type 'string | undefined' is not assignable to 'string'\n…"
}
```

`issue_count` is best-effort: inspector parses common output formats (one
issue per non-empty line, ignoring obvious headers/footers) where possible
and falls back to `null` when the format is unknown.

### `inspector.check.skipped`

Emitted when a check did not run.

```jsonc
{
  "file_path": "/abs/path/to/src/cart.ts",
  "file_path_relative": "src/cart.ts",
  "tool_name": "Edit",
  "check_name": "tsc",            // optional — absent for whole-file skips
  "reason": "tool_missing"        // tool_missing | disabled | excluded_path
                                  //   | no_extension_match | timeout
                                  //   | not_in_repo | total_budget_exhausted
}
```

### `inspector.run.completed`

Emitted once per hook invocation, after all per-check events for that file.

```jsonc
{
  "file_path": "/abs/path/to/src/cart.ts",
  "file_path_relative": "src/cart.ts",
  "tool_name": "Edit",
  "checks_run": 2,
  "checks_passed": 0,
  "checks_failed": 2,
  "checks_skipped": 0,
  "duration_ms": 1104
}
```

Downstream consumers that just want "did this edit produce broken code?" read
`inspector.run.completed` and check `checks_failed > 0`. Consumers that want
per-tool detail subscribe to `inspector.check.*`.

## Project-key derivation

Same algorithm as the rest of the ecosystem:

```
SHA256("remote:" + git remote get-url origin) → first 12 hex chars
  → fall back to SHA256("root:" + git rev-parse --show-toplevel)[:12]
  → fall back to SHA256("cwd:" + pwd)[:12]
```

Implemented in `plugins/inspector/scripts/lib/inspector-project-key.sh`,
mirroring the equivalent helper in cartographer.

## Failure modes and fail-soft behavior

Inspector is advisory. It never blocks the tool call. Specifically:

- Missing tool on PATH → `.skipped` event, no agent-facing output
- Timeout → `.skipped` event, agent sees `inspector: src/foo.ts — biome timed out`
- Hook script error → exit 0 with no event (last-resort; logged to
  `~/.onlooker/inspector/<project>/hook.log`)
- Schema validation error → logged to stderr, hook continues
- Concurrent invocation → no lock; each check runs independently. tsc's own
  incremental cache handles concurrent invocations safely

The "exit 0 with no event" path is the only case where inspector goes silent.
This is deliberate: inspector is a noticeably new behavior surface; bugs in the
hook script must not block writes.

## Open questions

These are deferred to a follow-up ADR after first real-world use.

1. **Output filtering for whole-project checks.** Filtering tsc/mypy output to
   the touched file is necessary for "only what you broke just now" UX. But
   compile errors in unrelated files often *are* caused by this edit (a removed
   export breaks five importers). Showing only the touched-file errors hides
   real damage; showing all errors floods the channel. Tentative: show only
   touched-file errors by default; add `inspector.show_collateral_errors`
   config knob if requests come in.
2. **Caching.** Repeated edits to the same file within seconds will re-run all
   checks. Worth caching at the level of "skip identical file content"? Not
   for v1.
3. **Parallel checks.** Checks for the same file run sequentially today. Worth
   parallelizing? Not for v1 — most lints finish in <500ms and bash-level
   parallelism with timeouts is fiddly.

[assayer]: ../../assayer/docs/design.md

# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

> **Architecture in one line:** Issues live in a local Dolt database
> (`.beads/dolt/`); cross-machine sync uses `bd dolt push/pull` (a
> git-compatible protocol), stored under `refs/dolt/data` on your git
> remote — separate from `refs/heads/*` where your code lives.
> `.beads/issues.jsonl` is a passive export, not the wire protocol.
>
> See [SYNC_CONCEPTS.md](https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md)
> for the one-screen overview and anti-patterns (don't treat JSONL as the
> source of truth; don't `bd import` during normal operation; don't
> reach for third-party Dolt hosting before trying the default).

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- The sections below are mirrored from CLAUDE.md. The two files are
     independent — not symlinked, not sharing an inode — so an edit to the
     repository's conventions must land in both or agents get different
     instructions depending on which file their harness reads. Claude Code
     reads CLAUDE.md; Codex and several other tools read this one. -->

## Repository layout

```
ecosystem/                    ← substrate plugin (always-on observability)
  hooks/                      ← session, tool, and prompt hooks
  scripts/lib/                ← shared bash helpers and the canonical event emitter
  skills/                     ← user-invocable slash commands
  config.json                 ← ecosystem defaults

plugins/
  archivist/                  ← session memory across context truncation
  bursar/                     ← multi-session, per-project budget rollup (governor's cross-session view)
  cartographer/               ← instruction-file auditor (CLAUDE.md, AGENTS.md, rules/)
  compass/                    ← pre-write alignment gate (design phase)
  echo/                       ← prompt-change regression detection
  governor/                   ← resource governance and budget enforcement
  inspector/                  ← per-edit lint and typecheck gate
  lineage/                    ← per-change provenance ("why does this line exist?")
  tribunal/                   ← multi-agent quality gate (Actor → Jury → Meta-Judge → Gate)

docs/
  architecture.md             ← how plugins compose and share the event bus
  adr/                        ← ecosystem-level architectural decisions

scripts/lib/onlooker-event.mjs  ← canonical event builder; all plugins route through this
~/.onlooker/                    ← shared runtime storage (logs, plugin artifacts)
```

## Plugin map

| Plugin | Hook surface | When it fires |
|--------|-------------|---------------|
| ecosystem | SessionStart/End, PreToolUse, PostToolUse, PostToolUseFailure, UserPromptSubmit, UserPromptExpansion, PreCompact, PostCompact, TaskCreated, TaskCompleted, WorktreeCreate, WorktreeRemove | Always — substrate |
| archivist | PreCompact, SessionStart | Extracts decisions/dead-ends on compaction; reinjects at next SessionStart |
| cartographer | SessionStart, PostToolUse (Write, Edit, MultiEdit) | Audits instruction files on session start and after instruction-file writes |
| compass | PreToolUse (Write, Edit, MultiEdit, Bash) | Before any write — alignment check |
| echo | Stop | Regression-tests prompt changes after each agent stop |
| governor | SessionStart, PreToolUse (Task), PostToolUse (Task), Stop | Budget gates on subagent spawns; tracks spend per session |
| tribunal | Stop + skill invocation | Post-task quality gate; also invokable via `/tribunal` |
| warden | PostToolUse (WebFetch, Read), PreToolUse (Write, Edit, MultiEdit, Bash), SessionStart + skill invocation | Scans ingested content for injection; closes a content gate that blocks write-class tools until cleared via `/warden` |
| assayer | Stop | Verifies the agent's final-message claims against actual command results in the transcript; advisory |
| bursar | SessionStart, SessionEnd | Rolls each session's spend into a per-project ledger on SessionEnd; surfaces "this project burned $X this week" at SessionStart. Governor is per-session; bursar is the cross-session rollup |
| lineage | PostToolUse (Edit, Write, MultiEdit) + skill invocation | Records per-change provenance (session_id/turn + redacted, size-capped snippets) into a per-project ledger; `/lineage <file>:<line>` answers "why does this line exist?" by joining records to historian transcripts to recover prompt context |
| inspector | PostToolUse (Write, Edit, MultiEdit) | Per-edit verification: runs the project's configured lint + typecheck commands on just the touched file and emits `inspector.check.*` / `inspector.run.completed`. Surfaces issues to the agent for the next turn. Cheaper than the planned proctor (which runs the full project verify at Stop); complements assayer (which catches claims the agent makes without running anything) |
| librarian | SessionEnd, SessionStart + skill invocation | Consolidation layer between archivist's per-session artifacts and the user's durable typed memory store. At SessionEnd, decides which decisions/dead-ends deserve to outlive the session, classifies them into user/feedback/project/reference, and queues them as proposals; at SessionStart, surfaces a one-line pointer to the queue. Propose-only (its ADR-001) — auto-promotion is opt-in. Also owns the lesson-promotion pipeline under `lessons/`, walked via `/librarian lessons` |
| historian | SessionEnd, UserPromptSubmit | Episodic memory. Chunks and sanitizes the transcript at SessionEnd into `$ONLOOKER_DIR/historian/<project-key>/sessions/`; on UserPromptSubmit, embeds the prompt and retrieves similar past chunks. Lineage joins these transcripts to recover the prompt context behind a change |
| counsel | SessionStart + skill invocation | Weekly synthesis across every plugin's event log. Produces a structured improvement brief and injects it at SessionStart when the last one is stale; `/counsel` on demand |
| curator | SessionStart | Maintenance for the typed auto-memory store. Runs four cheap heuristic checks (date_decayed, path_broken, broken_index, orphaned_memory) inside a wall-clock budget and surfaces findings as a one-line pointer. Never edits the memory store directly. The `/curator review` walkthrough and the LLM contradiction sweep are both deferred — see the plugin's README |
| scribe | SessionStart, UserPromptSubmit, Stop | Intent documentation from agent activity: captures why changes were made — problem context, decisions, tradeoffs — and distills them into readable artifacts at session end |

Plugins communicate by emitting events to the JSONL log — they do not call each other directly. All plugins depend on the ecosystem substrate; no plugin depends on another plugin directly.

## Compass plugin (design phase)

Compass is the pre-write alignment gate. It ships four hooks, eight libs, a calibrated config, and five bats files; `plugins/compass/docs/design.md` is the design record, not a statement of what exists. It is implemented but **not enabled** — it lands in wave 4 of the dogfooding rollout, last and one gate at a time, because it is the most behaviorally aggressive plugin in the set.

**What it does:** Fires on `PreToolUse` for write-class tools. Samples N=5 parallel Haiku evaluators to score intent clarity. Blocks when `confidence < 0.65 OR stddev > 0.20` and surfaces a clarification prompt.

**Critical architectural decision (ADR-001):** The evaluator must see the **prior assistant turn** alongside the current context — not the current context alone. Evaluating a reply in isolation produces a systematic false-positive class: a user answering an agent's enumerated question ("the internal one") looks ambiguous without the question that prompted it.

The pipeline is:

```
Trigger Gate → Transcript Reader → Symbolic Skip Layer → Sanitizer → N=5 Evaluators → Gate
```

- **Transcript reader** resolves `prior_assistant_turn` from `transcript_path` in the hook JSON payload (same field tribunal-stop-gate.sh reads). Reads one turn back from that file (already committed before `PreToolUse` fires — no timing-skew risk). If `transcript_path` is absent or unreadable, proceeds with an empty prior turn.
- **Symbolic skip layer** short-circuits to `confident` when the prior turn is an enumerated question and the current context is an option reference, without an LLM call. Controlled by `skip_patterns.reply_to_question.enabled` (default `true`).
- **Evaluator prompt** uses a structured pair: `<prior_assistant_turn>` and `<context_excerpt>` as separate XML-delimited slots. The convergence question is: *"Given the prior assistant turn as context, would two independent readers converge on the same interpretation of this write?"*

See `plugins/compass/docs/adr/001-evaluate-prompts-in-context.md` for the full decision record.

## Adding a new plugin

1. Create `plugins/<name>/` with `.claude-plugin/plugin.json`, `config.json`, `hooks/hooks.json`.
2. Use `scripts/lib/onlooker-event.mjs` for all event emission — never write directly to the JSONL log.
3. Store runtime artifacts under `${ONLOOKER_DIR:-$HOME/.onlooker}/<name>/<project-key>/`. Always use `$ONLOOKER_DIR` — never hardcode `~/.onlooker` — so the test suite's isolated temp home is respected.
4. Derive the project key via `tribunal_project_key` (or equivalent) — first 12 hex chars of SHA256(`remote:<origin-url>`), falling back to SHA256(`root:<repo-root>`) for repos without a remote. See `plugins/tribunal/scripts/lib/tribunal-project-key.sh`.
5. Register event types in `@onlooker-community/schema` before emitting them. The runtime emitter is dependency-free and **fails open**: it validates against the schema package only when that package is resolvable (dev, CI, tests) and emits unconditionally otherwise, because installed marketplace plugins ship no `node_modules`. Schema drift is caught in CI against the published schemas at `schema.onlooker.dev`. See [ADR-005](docs/adr/005-runtime-emitter-fails-open.md).
6. Triage every new event type into `test/bus-coverage.json` — `expected` when
   a test drives the branch that emits it, `excluded` with a reason when not.
   `npm run test:bus` fails on any registered type that appears in neither list.
7. Fail-soft when `~/.onlooker/` is absent — plugins must not block a session they were not invited to.
8. In `plugins/<name>/scripts/lib/<name>-config.sh`, source the **vendored** `config-loader.sh` that
   sits beside it, resolved from the file's own `${BASH_SOURCE[0]}`. Never from a caller-supplied
   `$PLUGIN_ROOT`, and never through a path that climbs to the repo root — both mistakes end the same
   way, with every accessor undefined while the script still exits 0, so config silently falls back to
   shipped defaults. `$PLUGIN_ROOT` is read at source time from whatever scope did the sourcing, so a
   sub-shell inheriting `CLAUDE_PLUGIN_ROOT` but not `PLUGIN_ROOT` loses it. A repo-root path resolves
   in this checkout and nowhere else: an installed plugin publishes rooted at `plugins/<name>` and has
   no ecosystem tree above it. Edit the canonical `scripts/lib/config-loader.sh`, then run
   `scripts/sync-shared-libs.sh` to propagate it. `test/bats/config-lib-self-locating.bats` enforces
   all of this across every plugin, including from a copied-out standalone tree. `hook-health.sh` is
   vendored the same way and for the same reason, propagated by the same script and guarded by
   `test/bats/shared-lib-vendoring.bats`.
9. In the hook script itself, source the vendored `hook-health.sh` and call
   `hook_health_register "<hook-filename-without-.sh>"` near the top of the script, before any real
   work happens. Once stdin has been read, call `hook_health_context "$INPUT"` so the record picks up
   `session_id`, `tool_name`, and `hook_event`. Skip either step and the hook is invisible to latency
   measurement — it silently reports nothing to `hook-health.jsonl`, with no error and no test failure
   to flag it. `test/bats/hook-health.bats` enforces that every hook under `plugins/*/scripts/hooks/*.sh`
   calls `hook_health_register`.
10. If the hook needs `$ONLOOKER_DIR` or `$ONLOOKER_EVENTS_LOG`, source the vendored
    `ecosystem-root.sh` and call `onlooker_ecosystem_root`, then keep your own `-f` guard before
    sourcing `validate-path.sh`. Never open-code the glob that finds the ecosystem. Fifteen hooks did,
    and every copy carried the same two defects: two dirnames where three are needed, so the guard
    tested `.../<v>/scripts/scripts/lib/validate-path.sh` and the substrate was never sourced
    (`ecosystem-449.36`), and a lexical `break`-on-first-hit that bound `0.33.1` over `0.49.2`
    (`ecosystem-449.35`). Sourcing the substrate is what exports `ONLOOKER_EVENTS_LOG`, so the failure
    is invisible in any plugin whose emit lib defaults its own sink and total in one that does not —
    curator, historian and librarian each stopped emitting within 60ms of each other and stayed silent
    for 34 days. It is vendored on demand, so a plugin adopting it copies it in once, then
    `scripts/sync-shared-libs.sh` keeps it fresh; `test/bats/hook-substrate-resolution.bats` fails on
    any hook that re-derives a root by nested `dirname`.

## Development

```bash
mise install          # installs all tools declared in mise.toml
npm ci
npm test              # bats + schema validation
npm run test:ci       # shellcheck + bats + schema + lint
```

Tests use an isolated temp home; nothing writes to your real `~/.onlooker/`.

## Git workflow

**Always open a PR — never push directly to `main`.** Even though bypass rights allow direct pushes, this repo uses release-please for automated changelogs and versioning, so every change must travel through a PR to be picked up correctly. CI also runs on PRs before merge, catching failures before they land.

Workflow:
1. Create a feature branch: `git switch -c <type>/<short-description>`
2. Commit using `/commit`
3. Push the branch and open a PR using `/git-workflow:pr`
4. Wait for CI to pass before merging

## Conventions

- All hooks are bash scripts. No Python, no Node entry points in hook scripts (they may shell out to `node` for event emission or heavy lifting).
- Hook scripts source shared helpers from `scripts/lib/` (or the plugin's own `scripts/lib/`).
- Event types follow `<plugin>.<noun>.<verb>` — e.g. `compass.check.skipped`, `tribunal.gate.blocked`.
- ULIDs everywhere for IDs (not UUIDs). Each plugin ships its own `*_ulid` helper (e.g. `archivist-ulid.sh`, `tribunal-ulid.sh`); there is no shared ecosystem helper. Copy `plugins/tribunal/scripts/lib/tribunal-ulid.sh` as a starting point and rename the function prefix.
- Config defaults live in `config.json`. User overrides go in `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project) under the plugin's namespace key (e.g. `"compass"`, `"tribunal"`). See ADR-004.

<!-- Every `bd`-generated block is fenced by markdownlint-disable/enable pairs.
     `bd setup` rewrites whatever sits between BEGIN and END verbatim, so any
     fix `npm run lint` applies inside a block is undone the next time anyone
     regenerates it. CI runs `lint:check`, which reports but never rewrites, so
     the churn lands as a red build unrelated to whatever that person was doing.
     The pairs sit *outside* the markers so `bd` does not clobber them.
     MD012 (consecutive blank lines), MD024 (duplicate headings) and MD034
     (bare URLs) are the rules the generated text trips. See ecosystem-55g.
     scripts/lint/check-managed-blocks.mjs enforces that every block is fenced. -->
<!-- markdownlint-disable MD012 MD024 MD034 -->
<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See <https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md> for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
<!-- markdownlint-enable MD012 MD024 MD034 -->

<!-- The Codex block below repeats the "Beads Issue Tracker" heading from the
     integration block above. Both are generated and re-synced by different `bd`
     subcommands, so neither heading can be renamed by hand without breaking
     idempotent regeneration. -->
<!-- markdownlint-disable MD012 MD024 MD034 -->
<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
<!-- markdownlint-enable MD012 MD024 MD034 -->

# Onlooker Ecosystem — Agent Instructions

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
| lineage | PostToolUse (Edit, Write, MultiEdit) + skill invocation | Records the prompt/agent/session behind each file change into a per-project ledger; `/lineage <file>:<line>` answers "why does this line exist?" by joining records to historian transcripts |

Plugins communicate by emitting events to the JSONL log — they do not call each other directly. All plugins depend on the ecosystem substrate; no plugin depends on another plugin directly.

## Compass plugin (design phase)

Compass is the pre-write alignment gate. It has no implementation yet. Design lives in `plugins/compass/docs/design.md`.

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
5. Register event types in `@onlooker-community/schema` before emitting them (the emitter validates the envelope).
6. Fail-soft when `~/.onlooker/` is absent — plugins must not block a session they were not invited to.

## Development

```bash
mise install          # installs all tools declared in mise.toml
npm ci
npm test              # bats + schema validation
npm run test:ci       # shellcheck + bats + schema + lint
```

Tests use an isolated temp home; nothing writes to your real `~/.onlooker/`.

## Conventions

- All hooks are bash scripts. No Python, no Node entry points in hook scripts (they may shell out to `node` for event emission or heavy lifting).
- Hook scripts source shared helpers from `scripts/lib/` (or the plugin's own `scripts/lib/`).
- Event types follow `<plugin>.<noun>.<verb>` — e.g. `compass.check.skipped`, `tribunal.gate.blocked`.
- ULIDs everywhere for IDs (not UUIDs). Each plugin ships its own `*_ulid` helper (e.g. `archivist-ulid.sh`, `tribunal-ulid.sh`); there is no shared ecosystem helper. Copy `plugins/tribunal/scripts/lib/tribunal-ulid.sh` as a starting point and rename the function prefix.
- Config defaults live in `config.json`. User overrides go in `~/.claude/settings.json` (global) or `.claude/settings.json` (per-project) under the plugin's namespace key (e.g. `"compass"`, `"tribunal"`). See ADR-004.

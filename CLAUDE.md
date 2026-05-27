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
  cartographer/               ← instruction-file auditor (CLAUDE.md, AGENTS.md, rules/)
  compass/                    ← pre-write alignment gate (design phase)
  echo/                       ← prompt-change regression detection
  governor/                   ← resource governance and budget enforcement
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
| ecosystem | SessionStart/End, PreToolUse, PostToolUse, UserPromptSubmit | Always — substrate |
| archivist | Stop | Extracts decisions/dead-ends; reinjects at next SessionStart |
| cartographer | Periodic background process | Audits instruction files for contradictions and dead rules |
| compass | PreToolUse (Write, Edit, MultiEdit, Bash) | Before any write — alignment check |
| echo | PostToolUse on agent file writes | Regression-tests prompt changes |
| governor | PreToolUse (Task spawns) | Budget gates on subagent spawns |
| tribunal | Stop + skill invocation | Post-task quality gate; also invokable via `/tribunal` |

Plugins communicate by emitting events to the JSONL log — they do not call each other directly. No plugin depends on another at runtime; any subset installs cleanly.

## Compass plugin (design phase)

Compass is the pre-write alignment gate. It has no implementation yet. Design lives in `plugins/compass/docs/design.md`.

**What it does:** Fires on `PreToolUse` for write-class tools. Samples N=5 parallel Haiku evaluators to score intent clarity. Blocks when `confidence < 0.65 OR stddev > 0.20` and surfaces a clarification prompt.

**Critical architectural decision (ADR-001):** The evaluator must see the **prior assistant turn** alongside the current context — not the current context alone. Evaluating a reply in isolation produces a systematic false-positive class: a user answering an agent's enumerated question ("the internal one") looks ambiguous without the question that prompted it.

The pipeline is:

```
Trigger Gate → Transcript Reader → Symbolic Skip Layer → Sanitizer → N=5 Evaluators → Gate
```

- **Transcript reader** resolves `prior_assistant_turn` from `CLAUDE_TRANSCRIPT_PATH` or the Onlooker JSONL event log filtered by `session_id`. Reads one turn back (already committed before `PreToolUse` fires — no timing-skew risk).
- **Symbolic skip layer** short-circuits to `confident` when the prior turn is an enumerated question and the current context is an option reference, without an LLM call. Controlled by `skip_patterns.reply_to_question.enabled` (default `true`).
- **Evaluator prompt** uses a structured pair: `<prior_assistant_turn>` and `<context_excerpt>` as separate XML-delimited slots. The convergence question is: *"Given the prior assistant turn as context, would two independent readers converge on the same interpretation of this write?"*

See `plugins/compass/docs/adr/001-evaluate-prompts-in-context.md` for the full decision record.

## Adding a new plugin

1. Create `plugins/<name>/` with `.claude-plugin/plugin.json`, `config.json`, `hooks/hooks.json`.
2. Use `scripts/lib/onlooker-event.mjs` for all event emission — never write directly to the JSONL log.
3. Store runtime artifacts under `~/.onlooker/<name>/<project-key>/`.
4. Derive the project key via `tribunal_project_key` (or equivalent) — SHA of `git remote get-url origin`.
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
- ULIDs everywhere for IDs (not UUIDs). Use `tribunal_ulid` or the ecosystem equivalent.
- Config defaults live in `config.json`; user overrides live in `~/.onlooker/<plugin>.json` or `.claude/<plugin>.json`. The merge order is: built-in defaults → user home → repo local.

# Plugin Catalog

The full set of Onlooker plugins — shipped and planned — grouped by the layer of agent behavior they address. Each entry is a sketch: name, status, hook surface, one-line purpose. Full design docs land in each plugin's own directory as the plugin is built.

**Status legend**

- **shipped** — code lives under `plugins/<name>/` and is exercised by the test suite
- **design** — design doc exists, no implementation
- **planned** — named only; this catalog is the first reference

**Layer map**

| Layer | What it does |
|---|---|
| quality | Judges output after the fact |
| governance | Enforces resource and policy limits |
| testing | Detects regressions in agents and prompts |
| safety | Blocks harmful or ambiguous actions before they land |
| analysis | Produces structured artifacts about the session and the repo |
| memory | Persists context across compaction and across sessions |
| discovery / routing | Surfaces the right ecosystem affordance for the moment |
| verification / execution | Runs the agent's output and reports whether it actually worked |
| feedback / adaptation | Detects user signals (corrections, reverts) and feeds them back |
| provenance | Links artifacts (files, decisions, commits) back to the prompts and agents that produced them |

---

## Quality

Post-hoc judgment of agent output.

- **tribunal** — shipped — Stop + skill. Multi-agent quality gate: Actor → typed Judges → Meta-Judge → gate decides accept / retry / exhaust.
- **muse** — planned — UserPromptSubmit. Optional prompt-clarification pass that rewrites a vague prompt into a sharper one before the agent acts. Distinct from compass (which blocks) — muse reshapes.
- **rubric** — planned — skill only. Manages and versions the scoring rubrics that tribunal and echo consume; `/rubric` diffs or rolls back rubric revisions.

## Governance

Resource and policy enforcement.

- **governor** — shipped — SessionStart, PreToolUse(Task), PostToolUse(Task), Stop. Per-session token and cost spend tracking; gates Task spawns against a configurable budget ceiling.
- **bursar** — planned — SessionEnd. Per-project, multi-session budget accounting; surfaces "this project burned $X this week" at SessionStart. Governor is per-session; bursar is the rollup.
- **arbiter** — planned — PreToolUse. Resolves cross-plugin conflicts (e.g., warden gate is closed but tribunal wants to spawn an Actor) using a declared precedence policy.

## Testing

Regression detection for agents and prompts.

- **echo** — shipped — Stop. Single-judge quality pass when a watched agent file changes; compares the score against a stored baseline to report improved / degraded / neutral.
- **canary** — planned — cron / scheduled. Synthetic prompts run against watched agents on a schedule; detects drift without waiting for a file edit.
- **gauntlet** — planned — skill only. Adversarial fixture suite (jailbreaks, ambiguous prompts, edge cases) run on demand against a chosen agent.

## Safety

Block harmful or ambiguous actions before they land.

- **compass** — shipped — PreToolUse(Write, Edit, MultiEdit, Bash). Pre-write intent clarity gate. N=5 parallel Haiku evaluators score whether two independent readers would converge on the same interpretation; blocks below threshold.
- **warden** — shipped — PostToolUse(WebFetch, Read), PreToolUse(Write, Edit, MultiEdit, Bash), SessionStart. Scans ingested content for prompt-injection patterns; closes a session-scoped gate that blocks write-class tools until cleared.

## Analysis

Structured artifacts describing the session and the repo.

- **cartographer** — shipped — SessionStart, PostToolUse(Write, Edit, MultiEdit). Audits the persistent instruction layer (CLAUDE.md, AGENTS.md, .claude/rules/) for contradictions, shadowing, and drift.
- **counsel** — shipped — SessionStart. Weekly synthesis brief across all plugin event logs; injected when the last brief is stale.
- **scribe** — shipped — SessionEnd. Distills the session's "why" — problem context, decisions, tradeoffs — into a readable artifact.

## Memory

Context that survives compaction and sessions.

- **archivist** — shipped — PreCompact, SessionStart. Extracts decisions, dead-ends, and open questions on compaction; reinjects the most important ones at the next SessionStart.
- **historian** — shipped — SessionEnd. Chunks and sanitizes the session transcript and stores chunks locally for future retrieval. Indexing pipeline only; retrieval lands in a follow-up.
- **librarian** — shipped — SessionEnd, skill. Consolidates archivist's per-session artifacts into the user's durable typed memory store; queues classified proposals for explicit confirmation.
- **curator** — shipped — SessionStart, skill. Maintenance pass over the typed memory store: four cheap heuristic checks (date decay, broken paths, broken index, orphaned memory) inside a wall-clock budget; surfaces findings, never edits the store directly.

## Discovery / Routing

Help the agent and the user find the right affordance for the moment.

- **wayfinder** — planned — UserPromptSubmit. Ranks ecosystem plugins, skills, and agents against the current prompt; surfaces the top 1–2 as a `wayfinder.suggestion` event.
- **herald** — planned — SessionStart. Announces plugins, skills, or agents added since the user's last session in this project. One-time per item, dismissable.
- **dispatcher** — planned — UserPromptSubmit. Narrow intent classifier ("commit", "ship a PR", "review changes") that maps directly to the canonical skill. Narrower than wayfinder; fewer false positives.

## Verification / Execution

Run the agent's output. Report what actually happened.

- **proctor** — planned — Stop, PostToolUse(Edit, Write). Runs the project's verification command (configurable: `npm test`, `mise run check`, `cargo test`, …) after writes or at Stop; emits `proctor.verify.passed` or `.failed`.
- **assayer** — planned — Stop. Parses the agent's final message for testable claims ("I ran the tests", "the build passes") and verifies them against actual exit codes in the session log. Catches lying-without-malice.
- **inspector** — planned — PostToolUse(Edit, Write). Runs lint and typecheck on just the touched files. Cheaper than proctor; fires far more often.

## Feedback / Adaptation

Detect user signals and feed them back into the system.

- **attendant** — planned — UserPromptSubmit. Detects course-corrections in the user's prompt ("no", "stop", "don't", revert patterns); emits `attendant.pushback.detected` for other plugins to consume.
- **interpreter** — planned — consumes attendant events. Classifies pushback tone (frustrated / clarifying / neutral) so downstream plugins don't overreact to clarifying questions.
- **adept** — planned — SessionStart. Accumulates pushback patterns over sessions; injects "you've corrected this pattern N times" hints. Closes the loop that echo opens for prompt files.

## Provenance

Link artifacts back to the prompts and agents that produced them.

- **lineage** — planned — PostToolUse(Edit, Write, MultiEdit). Records the prompt + agent + session that produced each file change; builds a queryable graph by joining historian transcripts with tool-use events. Answers "why does this line exist?"
- **ledger** — planned — PostToolUse(*) write-class. Append-only audit record of every write-class tool call with the prompt and agent context attached. `/ledger` queries by file, prompt substring, or time range.
- **witness** — planned — Stop. Captures the deciding assistant turn — the moment the agent committed to a course of action — and stores it as a discrete artifact. Distinct from scribe (which writes a narrative) — witness preserves the pivot itself.

---

## Coverage check

| Layer | Plugins |
|---|---|
| quality | tribunal, muse, rubric |
| governance | governor, bursar, arbiter |
| testing | echo, canary, gauntlet |
| safety | compass, warden |
| analysis | cartographer, counsel, scribe |
| memory | archivist, historian, librarian, curator |
| discovery / routing | wayfinder, herald, dispatcher |
| verification / execution | proctor, assayer, inspector |
| feedback / adaptation | attendant, interpreter, adept |
| provenance | lineage, ledger, witness |

Every layer holds at least two plugins; most hold three. Total: 12 shipped, 0 design, 17 planned.

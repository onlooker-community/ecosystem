# Curator — Plugin Design

**Plugin name:** `curator`
**Tagline:** *Tends the memory garden.*
**Status:** Design (pre-implementation)

Curator is the maintenance layer for the user's typed memory store. It runs cheap heuristic checks at every `SessionStart` and an LLM-backed conflict sweep at most weekly, surfaces stale references, decayed dates, and contradicting entries, and proposes prunes for user review. It does not edit the memory store directly — the same posture librarian and cartographer adopt for durable substrates.

It sits in the [memory architecture](../../../docs/memory-architecture.md) downstream of librarian: librarian writes (with user confirmation); curator audits. Curator is parallel to cartographer: same shape (audit, propose, surface), different substrate. Cartographer audits hand-maintained instruction files (CLAUDE.md, AGENTS.md, `.claude/rules/`); curator audits the typed auto-memory store at `~/.claude/projects/<encoded-project>/memory/`.

---

## Failure Modes Curator Addresses

**A — Decayed date references.** A project memory says "merge freeze begins 2026-03-05 for mobile release cut." After March 5 passes, the memory is at best uninformative and at worst misleading (the model continues to flag work as freeze-sensitive). Curator detects past-tense date markers and proposes removal or refactor.

**B — Stale path references.** A reference memory says "see `scripts/legacy_ingest.py` for the old pipeline shape." The file has since been deleted. The memory now points to nothing. Curator validates path references on a periodic sweep and flags broken ones.

**C — Contradicting memories.** A user memory says "prefer functional patterns" and a feedback memory says "yes, the class-based approach was right for this hot path." Both are true in their original contexts. The model has to reconcile them at runtime, often badly. Curator's LLM-backed sweep finds high-similarity, opposing-sentiment pairs and surfaces the contradiction for human disambiguation.

**D — Unused memories (weakest signal).** A memory has been in the store for 90 days and has never been surfaced as relevant in any session (signal: no `memory.recalled` event references it). It might be load-bearing as a backstop, or it might be dead weight. Curator flags but does not propose removal — the signal is too noisy for action.

**E — Type drift.** A `project` memory ("we're rewriting auth for compliance") becomes a `feedback` memory ("this directory looks weird because of legal review") once the rewrite is done. The original type still fits but a better type now exists. Curator can detect type-drift candidates but the action (re-classification) is necessarily manual.

---

## Architecture

```
SessionStart hook fires
        │
        ▼
┌──────────────────────┐
│   Rate Gate          │  cheap checks: every session
│                      │  LLM checks: once per llm_sweep_interval_days
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│  Memory Reader       │  reads MEMORY.md + *.md files from memory store
│                      │  parses frontmatter (name, description, type)
└─────────┬────────────┘
          │
          ▼ (cheap sweep, every session)
┌──────────────────────┐
│  Date Checker        │  parse dates from bodies; flag past-tense markers
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│  Reference Checker   │  validate path refs (file exists), symbol refs
│                      │  (rg the symbol; warn on zero matches), URL refs
│                      │  (HEAD with budget; skipped without consent)
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│  Usage Tracker       │  read JSONL log; correlate memory IDs with
│                      │  memory.recalled events from N days
└─────────┬────────────┘
          │
          ▼ (LLM sweep, if interval elapsed)
┌──────────────────────┐
│  Similarity Matrix   │  Jaccard on token sets; pairs with sim > threshold
│                      │  → LLM contradiction check
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│  Findings Store      │  ~/.onlooker/curator/<key>/findings/<ulid>.json
└─────────┬────────────┘
          │ at SessionStart
          ▼
┌──────────────────────┐
│ Surfacer             │  "Curator: 2 stale, 1 contradicting findings."
│                      │  Review via /curator review.
└──────────────────────┘
```

### Rate Gate

Three categories of check, three cadences:

- **Cheap checks (date, reference, usage):** run every `SessionStart`. Combined wall-clock budget: ≤500ms. Above that, curator emits `curator.scan.skipped` with `reason: "over_budget"` and defers.
- **LLM contradiction sweep:** runs at most once per `llm_sweep_interval_days` (default: 7) per project. Watermark stored at `~/.onlooker/curator/<project-key>/last_llm_sweep.json`.
- **Manual sweep:** `/curator scan` forces a full sweep including the LLM pass, ignoring rate gates.

The rate gate exists because curator runs on every session start, and a quadratic LLM pass on a growing memory store is the worst kind of background cost: invisible, recurring, and proportional to user investment.

### Memory Reader

Parses the typed memory store:

1. Reads `~/.claude/projects/<encoded-project>/memory/MEMORY.md` for the index entries.
2. For each line of the form `- [Title](file.md) — hook`, resolves `file.md` against the memory dir.
3. Reads each referenced file. Parses YAML frontmatter (`name`, `description`, `type`). The body after frontmatter is the memory content.
4. If a file is referenced from `MEMORY.md` but does not exist, that itself is a `findings.broken_index` — surfaced immediately.
5. If a file exists in the memory dir but is not referenced from `MEMORY.md`, that is `findings.orphaned_memory` — also surfaced.

### Date Checker

For each memory body, scans for date patterns and absolute references:

- **ISO-8601 dates** (`2026-03-05`, `2026-03-05T10:00:00Z`).
- **Quarter markers** (`Q1 2026`, `2026Q3`).
- **Named deadlines** with absolute dates nearby (`freeze`, `deadline`, `release cut`, `migration`, `cutover`, `EOL`, `expires`).
- **Relative-to-write markers** when the frontmatter has a discoverable write date (`promoted_at`, `created_at`): phrases like "next week", "by end of month", "this Friday" relative to that date.

For each match, compares to today's date. If a date is more than `date_grace_period_days` (default: 14) in the past, emits `curator.finding.date_decayed` with the matched phrase and the gap in days.

The check does not propose removal automatically — past dates often have lingering relevance ("freeze on 2026-03-05" might still document why a code shape is the way it is). The user decides whether to remove, refactor, or keep.

### Reference Checker

For each memory body, scans for two kinds of references:

1. **Path references.** Patterns matching `path/to/file.ext` heuristics. For each candidate path, resolves against the repo root (from `git rev-parse --show-toplevel`). If the path does not exist, emits `curator.finding.path_broken` with the memory file and the broken path.
2. **Symbol references.** Heuristic: backtick-wrapped identifiers (`` `myFunction` ``, `` `MyClass` ``) that look like code identifiers (CamelCase or snake_case with no spaces, length ≥ 3). For each, runs `rg --type-add 'all:*' --type all -F 'identifier'` in the repo root. If zero matches, emits `curator.finding.symbol_missing`.
3. **URL references.** Optional, disabled by default. When `check_urls: true` and the URL host is not in `url_allowlist`, curator emits `curator.finding.url_unchecked` (a record that the memory contains an external URL it cannot validate without network). URLs in the allowlist (and only those) are HEAD-checked under a wall-clock budget.

The reference checker treats matches as evidence of liveness, not correctness. A symbol that grep-matches might still be the wrong symbol; a path that resolves might point to renamed content. The checker is a smoke alarm, not a smoke detector.

### Usage Tracker

Reads `~/.onlooker/logs/onlooker-events.jsonl` (rate-limited; the tail is enough for usage windows) for events of type `memory.recalled` and `memory.referenced` over the last `usage_window_days` (default: 30). For each memory file, computes recall count.

The Onlooker event log does not yet emit `memory.recalled` events. Adding that emitter belongs to the ecosystem substrate (so all plugins benefit), not to curator. Until it ships, the usage tracker emits `curator.finding.unused_undetectable` once per scan and skips the rest of the pass. This is recorded as a hard dependency in [Open Questions #1](#open-questions).

When the emitter ships: memories with zero recalls in the window are flagged `curator.finding.unused_low_signal`. The finding is informational only — the design does not propose removal based on usage alone, because the recall signal is itself noisy (the model may not surface a memory it should have, and a recalled memory may have been irrelevant).

### Similarity Matrix and Contradiction Check (LLM sweep)

Run at most once per `llm_sweep_interval_days`:

1. Compute pairwise Jaccard similarity over normalized token sets (lowercased, stopwords removed, top-K tokens per body).
2. Filter to pairs where similarity ≥ `contradiction_similarity_threshold` (default: 0.4) and where the two memories have at least one opposing sentiment marker (one contains `always`/`prefer`/`do` and the other contains `never`/`avoid`/`don't`).
3. For each surviving pair, call Haiku with both memory bodies and ask:

```
You are evaluating whether two memory entries contradict each other in practice.

Two memories CONTRADICT when applying both leads to inconsistent action.
Two memories COMPLEMENT when they apply in different contexts and a careful reader
   can follow both.
Two memories are REDUNDANT when one strictly subsumes the other.

RULES:
- Output only: {"verdict": "<contradict|complement|redundant|unrelated>",
                "rationale": "<≤30 words>"}

<memory_a>
title: {{TITLE_A}}
body: {{BODY_A}}
</memory_a>

<memory_b>
title: {{TITLE_B}}
body: {{BODY_B}}
</memory_b>
```

Model: `claude-haiku-4-5-20251001`. Temperature 0.2. Max output tokens: 96.

`contradict` verdicts become `curator.finding.contradiction`. `redundant` verdicts become `curator.finding.redundant_pair`. `complement` and `unrelated` are logged but not surfaced.

### Findings Store and Surfacer

Each finding is written to `~/.onlooker/curator/<project-key>/findings/<ulid>.json`:

```json
{
  "id": "01J...",
  "kind": "date_decayed | path_broken | symbol_missing | url_unchecked | unused_low_signal | contradiction | redundant_pair | broken_index | orphaned_memory",
  "memory_files": ["feedback_no_trailing_summaries.md"],
  "detail": { ... kind-specific ... },
  "created_at": "2026-06-02T18:24:11Z",
  "deduped_hash": "...",
  "status": "open | acknowledged | resolved"
}
```

The `deduped_hash` prevents the same finding from being re-emitted every session. Same shape as cartographer's `payload.finding_hash`.

At `SessionStart`, curator counts open findings by kind and emits a one-line `additionalContext` pointer:

> Curator: 1 contradiction, 2 path-broken, 1 date-decayed. Review with `/curator review`.

The pointer caps the inject at one line; findings details live in the skill, not in context.

---

## Integration Points

**Librarian.** Curator uses the `source: "librarian"` provenance to apply different staleness criteria to librarian-promoted memories vs. hand-written ones (open question — current default treats them identically).

**Cartographer.** Same shape; different substrate. They can run independently. Curator's findings format intentionally mirrors cartographer's so a future unified findings dashboard can render both.

**Ecosystem substrate.** Curator depends on a `memory.recalled` / `memory.referenced` event emitter that does not yet exist. Until it ships, the usage tracker is dormant.

**Counsel.** Counsel reads curator's findings as part of the weekly observability brief; curator does not need to know about counsel.

**Historian.** Independent. Curator audits the distilled memory store; historian operates on the transcript embeddings. A path that's stale in a memory is not made fresh by being in a transcript.

---

## Configuration (`config.json`)

```json
{
  "plugin_name": "curator",
  "storage_path": "${ONLOOKER_DIR:-$HOME/.onlooker}",
  "curator": {
    "enabled": false,
    "memory_store_path": "${HOME}/.claude/projects/${CLAUDE_PROJECT_ENCODED}/memory",
    "cheap_checks": {
      "enabled": true,
      "wall_clock_budget_ms": 500,
      "skip_if_session_age_under_seconds": 5
    },
    "date_check": {
      "enabled": true,
      "date_grace_period_days": 14
    },
    "reference_check": {
      "enabled": true,
      "check_urls": false,
      "url_allowlist": []
    },
    "usage_tracker": {
      "enabled": true,
      "usage_window_days": 30
    },
    "llm_sweep": {
      "enabled": true,
      "model": "claude-haiku-4-5-20251001",
      "temperature": 0.2,
      "max_output_tokens": 96,
      "interval_days": 7,
      "max_pair_evaluations_per_sweep": 50,
      "contradiction_similarity_threshold": 0.40
    },
    "surfacer": {
      "max_pointer_chars": 200,
      "skip_when_zero": true
    }
  }
}
```

`skip_if_session_age_under_seconds` exists because a session start followed quickly by another session start (compaction, restart) shouldn't re-run the cheap checks.

---

## Events

| Event | Trigger | Key payload fields |
|---|---|---|
| `curator.scan.started` | Scan run begins | `mode: cheap\|llm\|manual`, `findings_open_before` |
| `curator.scan.completed` | Scan run ends | `findings_new`, `findings_resolved`, `duration_ms` |
| `curator.scan.skipped` | Skipped by rate gate | `reason: over_budget\|llm_interval_not_elapsed\|disabled` |
| `curator.finding.date_decayed` | A dated phrase is past the grace period | `memory_file`, `matched_phrase`, `days_past` |
| `curator.finding.path_broken` | Path reference does not resolve | `memory_file`, `broken_path` |
| `curator.finding.symbol_missing` | Backticked identifier returns zero rg matches | `memory_file`, `symbol` |
| `curator.finding.url_unchecked` | URL present, host not in allowlist | `memory_file`, `url_host` |
| `curator.finding.unused_low_signal` | Zero recalls in window (when emitter exists) | `memory_file`, `window_days` |
| `curator.finding.unused_undetectable` | Usage emitter not present | `note: "memory.recalled events not implemented"` |
| `curator.finding.contradiction` | LLM verdict `contradict` | `memory_a`, `memory_b`, `rationale` |
| `curator.finding.redundant_pair` | LLM verdict `redundant` | `memory_a`, `memory_b`, `rationale` |
| `curator.finding.broken_index` | MEMORY.md references missing file | `referenced_file` |
| `curator.finding.orphaned_memory` | Memory file not referenced from MEMORY.md | `memory_file` |
| `curator.finding.acknowledged` | User acknowledged finding via skill (no action taken) | `finding_id` |
| `curator.finding.resolved` | User resolved finding via skill (action taken) | `finding_id`, `action: prune\|edit\|reclassify\|defer` |

---

## Skills

**`/curator review`** — interactive walkthrough of open findings. For each: shows the memory body excerpt, the finding kind and detail, and offers prune / edit / reclassify / acknowledge / defer.

**`/curator scan`** — forces a full sweep including the LLM pass. Ignores rate gates.

**`/curator calibrate`** — runs the LLM sweep against the current memory store and reports precision against a labeled set (which the user maintains in `~/.onlooker/curator/<project-key>/calibration_labels.json`). Useful for tuning `contradiction_similarity_threshold`.

---

## Open Questions

1. **`memory.recalled` event dependency.** The usage tracker requires an event emitter in the ecosystem substrate that does not yet exist. The substrate change is small (`UserPromptExpansion` hook can emit an event each time a memory is reinjected) but it is a prerequisite. Until then, the usage signal is dormant — `curator.finding.unused_undetectable` is emitted once per scan to make the missing capability visible.

2. **Librarian-promoted vs. hand-written staleness.** A librarian-promoted memory was distilled from a session; its staleness criteria might be "the source session is older than X." A hand-written memory has no equivalent decay marker. The current design treats them identically; the provenance field is captured but not yet used differently.

3. **LLM sweep cost growth.** Pairwise contradiction checks are O(N²) on pair candidates. At 100 memories with similarity-filtering, the sweep is typically under 10 LLM calls; at 500 memories the worst case approaches the `max_pair_evaluations_per_sweep` cap. A smarter pre-filter (e.g., embedding-based clustering to limit pair candidates) becomes worthwhile around 200 memories.

4. **Finding dedup vs. re-evaluation.** A `date_decayed` finding for `2026-03-05` is the same fact every session — `deduped_hash` prevents re-emission. But a `contradiction` finding between two memories may be re-evaluated if either memory's body changes; the dedup hash should include both bodies' hashes, not just memory IDs.

5. **Auto-prune as a future opt-in.** Like librarian's `auto_promote`, curator could grow an `auto_prune` mode for high-confidence findings (e.g., `path_broken` with no possible interpretation). Deferred until the cheap-check precision is measured in practice.

6. **Type-drift detection.** Mentioned as failure mode E but not addressed by the current checks. Would require an LLM call per memory: "given this body, what type fits best?" — too expensive for every session, plausible for the weekly sweep.

7. **Interaction with `~/.claude/CLAUDE.md`.** Global instructions in `~/.claude/CLAUDE.md` shape behavior but live outside the typed memory store. Curator does not audit them — cartographer does. If the boundary moves (e.g., librarian gains the ability to propose `~/.claude/CLAUDE.md` edits), curator and cartographer will need a shared rule for which substrate owns which file.

---

## Non-Goals

- Does not edit the memory store automatically — same posture as librarian and cartographer.
- Does not write new memories — that is librarian's job.
- Does not perform retrieval — the typed memory store reinjection mechanism is owned elsewhere.
- Does not audit instruction files (CLAUDE.md, AGENTS.md, `.claude/rules/`) — that is cartographer's job.
- Does not synthesize cross-session improvement briefs — that is counsel's job.
- Does not block any tool call — curator's surfacer is informational only.

# Librarian — Plugin Design

**Plugin name:** `librarian`
**Tagline:** *Promotes what's worth keeping.*
**Status:** Design (pre-implementation)

Librarian is the consolidation layer between archivist's per-session artifacts and the user's durable typed memory store. It watches what archivist writes during a session, decides which of those decisions, dead-ends, and open questions deserve to live beyond the session, classifies them into the existing memory types (user/feedback/project/reference), and proposes promotions for user confirmation. It does not write to the typed memory store automatically by default — see [ADR-001](adr/001-propose-dont-auto-write.md).

It sits in the [memory architecture](../../../docs/memory-architecture.md) between archivist (session-scoped) and curator (maintenance). Where archivist treats every session as fresh and ranks by recency, librarian asks: "should this fact survive across sessions, and if so, what kind of memory is it?"

---

## Failure Modes Librarian Addresses

**A — The same decision rediscovered every session.** A user explains why the auth middleware is being rewritten (legal compliance, not tech debt). Archivist captures it as a decision; it gets reinjected next session within the recency budget. Three sessions later it has aged out, and the agent re-asks "why are we rewriting this?" Librarian promotes load-bearing project facts into the typed memory store, where they don't decay on recency alone.

**B — Feedback observed but not generalized.** During a session, the user says "stop summarizing what you just did at the end of every response." The model corrects course for the rest of that session. Archivist may or may not capture it as a decision (it's not a code decision). Next session the model summarizes again. Librarian detects the corrective pattern, classifies it as `feedback`, and proposes it for the typed memory store with **Why:** and **How to apply:** fields filled in.

**C — Memory store starvation.** A user who never says "remember that…" ends up with a near-empty typed memory store, even after months of work. Archivist captures everything per-session but nothing accumulates. Librarian provides the promotion path that doesn't depend on the user explicitly invoking it.

**D — Pollution from automatic promotion (counter-failure).** If librarian wrote directly to the typed memory store, every false positive would silently bloat the file and degrade future sessions. The design avoids this by defaulting to propose-only — see [ADR-001](adr/001-propose-dont-auto-write.md).

---

## Architecture

```
SessionEnd hook fires (or skill invocation)
        │
        ▼
┌──────────────────────┐
│   Artifact Reader    │  reads archivist artifacts since last librarian
│                      │  scan; reads recent transcript tail for context
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│   Durability Filter  │  cheap heuristics — keep candidates that show
│                      │  signs of durability (repetition, marker phrases,
│                      │  explicit user preference language)
└─────────┬────────────┘
          │ candidates remain
          ▼
┌──────────────────────┐
│  Type Classifier     │  Haiku call: user / feedback / project / reference
│  (LLM)               │  emits null for "session-only — don't promote"
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│  Conflict / Dup      │  compare against existing memory files; merge,
│  Detector            │  supersede, or flag conflict
└─────────┬────────────┘
          │
          ▼
┌──────────────────────┐
│ Proposal Queue       │  written to ~/.onlooker/librarian/<key>/proposals/
│                      │                                                 │
└─────────┬────────────┘
          │ at next SessionStart
          ▼
┌──────────────────────┐
│ Surfacer             │  injects "Librarian proposes N promotions"
│                      │  pointer; full review via /librarian skill
└──────────────────────┘
```

### Artifact Reader

Reads `~/.onlooker/archivist/<project-key>/decisions/`, `dead_ends/`, and `open_questions/` for artifacts created since the last librarian scan. The last-scan watermark is `~/.onlooker/librarian/<project-key>/last_scan.json` (an ISO-8601 timestamp). On first run, librarian scans the last `bootstrap_lookback_days` (default: 14) of artifacts.

Each artifact carries `session_id` and `created_at`. Librarian groups candidates by `session_id` so the classifier has session-shaped context, not a flat fire-hose.

### Durability Filter

A cheap pre-LLM filter that drops obvious session-only items before paying for classification. Heuristics, in order:

1. **Marker-phrase boost.** Artifact summary or detail contains one of: `always`, `never`, `remember`, `from now on`, `every time`, `whenever`, `prefer`, `the reason`, `because`, `historically`, `legacy`, `compliance`, `requirement`. These markers correlate strongly with durable facts in calibration runs (target: ≥60% precision; revalidate per repo via `/librarian calibrate`).
2. **Reference grounding.** Artifact `files` field lists at least one path that still exists in the repo (paths that have been deleted suggest a fact about completed/abandoned work, not durable knowledge).
3. **Repetition across sessions.** Same canonical summary (after normalization: lowercased, stopwords removed, top-3 tokens) appears in archivist artifacts from ≥2 distinct sessions. Strong durability signal.
4. **Drop list.** Specific patterns that almost never promote well: "the test is failing", "let me check", "I'll come back to this", artifact whose detail is shorter than `min_detail_chars` (default: 40).

Filter outputs a candidate set. If the set is empty, librarian emits `librarian.scan.empty` and exits.

### Type Classifier

For each remaining candidate, librarian calls Haiku once with a structured prompt. The prompt presents the four memory types from the user's CLAUDE.md (user, feedback, project, reference) with examples, and asks the model to emit one of those four labels or `null` for "session-only — don't promote."

```
You are classifying a session artifact for promotion into a long-term memory store.

The store has four types:
- user: durable facts about the user's role, expertise, or working style
- feedback: corrections or validated preferences ("don't do X", "yes, keep doing Y")
- project: ongoing work facts, decisions, constraints not derivable from the code
- reference: pointers to external systems (issue trackers, dashboards, channels)

RULES:
- Output only JSON: {"type": "<user|feedback|project|reference|null>",
                     "title": "<≤60 chars>",
                     "body": "<the memory content; structure per type>",
                     "confidence": <float 0–1>}
- Use null when the artifact is interesting but session-only (a specific bug fix,
  a one-off question that got answered, an exploration that didn't change anything).
- For feedback and project types, include **Why:** and **How to apply:** lines.

<artifact>
kind: {{ARTIFACT_KIND}}
summary: {{SUMMARY}}
detail: {{DETAIL}}
files: {{FILES_LIST}}
session_id: {{SESSION_ID}}
created_at: {{CREATED_AT}}
</artifact>

<surrounding_session_context>
{{SESSION_CONTEXT_EXCERPT}}
</surrounding_session_context>
```

Model: `claude-haiku-4-5-20251001`. Temperature 0.2 (slight stability vs. 0 for noise-floor robustness). Max output tokens: 256.

Candidates with `confidence < min_classifier_confidence` (default: 0.6) are dropped silently — the cost of a missed promotion is low; the cost of a noisy proposal queue is high.

### Conflict / Duplicate Detector

For each surviving candidate, librarian:

1. Reads `MEMORY.md` and each referenced memory file from `~/.claude/projects/<encoded-project>/memory/`.
2. Computes token-set similarity (Jaccard on lowercased, stopword-stripped token sets) against each existing memory's body.
3. If max similarity ≥ `duplicate_threshold` (default: 0.7), classifies as `duplicate` — annotated and dropped from proposals, but logged as `librarian.candidate.dropped` with `reason: "duplicate"`.
4. If `merge_candidate_threshold` (default: 0.45) ≤ similarity < `duplicate_threshold`, classifies as `merge_candidate` — the proposal records the existing memory's filename so the surfacer can offer "merge into X" as a resolution path.
5. If `conflict_keyword_overlap` (default: 0.5) overlap on the body but opposing sentiment markers (`always`/`never`, `do`/`don't`, `prefer`/`avoid`), classifies as `conflict_candidate` — the surfacer offers "this contradicts X — supersede, keep both, or drop new."

Conflict detection at this stage is cheap pattern matching, not an LLM call. Curator does the deeper LLM-based contradiction sweep separately.

### Proposal Queue

Each proposal is written to `~/.onlooker/librarian/<project-key>/proposals/<ulid>.json`:

```json
{
  "id": "01J...",
  "created_at": "2026-06-02T18:24:11Z",
  "source_artifact_ids": ["01J...", "01J..."],
  "source_session_ids": ["..."],
  "proposed": {
    "type": "feedback",
    "filename": "feedback_no_trailing_summaries.md",
    "title": "Don't write trailing summaries",
    "body": "...",
    "classifier_confidence": 0.84
  },
  "conflict_state": "none | duplicate | merge_candidate | conflict_candidate",
  "conflict_with": ["existing_memory_filename.md"],
  "status": "pending | accepted | rejected | superseded"
}
```

### Surfacer

At `SessionStart`, librarian counts proposals where `status == "pending"`. If `count > 0`, it injects a single short pointer into `additionalContext`:

> Librarian has 4 pending memory promotion proposals. Review with `/librarian review`.

It does not inject the proposal bodies — the SessionStart context budget is precious and the user shouldn't have to skim them inline. The `/librarian review` skill walks the user through each proposal interactively, accepting, rejecting, or editing each one. Accepted proposals are written to the typed memory store with a provenance trailer:

```markdown
---
name: Don't write trailing summaries
description: user-specific terseness preference — corrected during session
type: feedback
source: librarian
source_session_id: 01J...
source_artifact_ids: ["01J...", "01J..."]
classifier_confidence: 0.84
promoted_at: 2026-06-02T19:01:33Z
---

Don't write trailing summaries of what you just did.

**Why:** User explicitly said "stop summarizing... I can read the diff" during session 01J...
**How to apply:** Treat the end of turn as a stopping point; surface only what's new since the user last looked, not a recap.
```

The provenance fields let curator later detect that a memory was librarian-promoted (so curator can use a different staleness heuristic for it) and trace a promoted memory back to the originating session if the user wants to investigate.

---

## Integration Points

**Archivist.** Librarian reads archivist's artifact directories. If archivist is not installed, librarian emits `librarian.scan.skipped` with `reason: "archivist_not_present"` and exits. Librarian does not require archivist to be running in the current session — it reads artifacts from the on-disk store, which is durable.

**Curator.** Once a memory is promoted, curator owns its maintenance. Librarian does not re-touch memories it has already promoted. The `source: "librarian"` provenance field tells curator which memories came through this pipeline; curator may want different staleness criteria for librarian-promoted memories vs. hand-written ones (open question).

**Historian.** Independent. A librarian-promoted memory is a distilled summary; the corresponding historian transcript chunk is the verbatim source. They complement each other and do not need cross-references at the storage level.

**Scribe.** Different goal. Scribe produces readable narrative artifacts of the session. Librarian produces structured durable knowledge. The same session might generate both. They can run in parallel without coordination.

**Compass / Tribunal / Warden / Echo / Governor.** No interaction.

---

## Configuration (`config.json`)

```json
{
  "plugin_name": "librarian",
  "storage_path": "${ONLOOKER_DIR:-$HOME/.onlooker}",
  "librarian": {
    "enabled": false,
    "auto_promote": false,
    "memory_store_path": "${HOME}/.claude/projects/${CLAUDE_PROJECT_ENCODED}/memory",
    "scan": {
      "trigger": "SessionEnd",
      "bootstrap_lookback_days": 14,
      "min_detail_chars": 40
    },
    "classifier": {
      "model": "claude-haiku-4-5-20251001",
      "temperature": 0.2,
      "max_output_tokens": 256,
      "min_classifier_confidence": 0.6
    },
    "durability_filter": {
      "marker_phrases": [
        "always", "never", "remember", "from now on", "every time",
        "whenever", "prefer", "the reason", "because", "historically",
        "legacy", "compliance", "requirement"
      ],
      "require_grounding": false,
      "repetition_min_sessions": 2
    },
    "conflict": {
      "duplicate_threshold": 0.70,
      "merge_candidate_threshold": 0.45,
      "conflict_keyword_overlap": 0.50
    },
    "surfacer": {
      "max_pending_for_inject": 20,
      "skip_inject_when_zero": true
    }
  }
}
```

`memory_store_path` resolves `${CLAUDE_PROJECT_ENCODED}` at hook time from the Claude Code project-path encoding scheme. If the env var is not set, librarian degrades to skill-only mode and emits `librarian.config.warning`.

---

## Events

| Event | Trigger | Key payload fields |
|---|---|---|
| `librarian.scan.started` | Scan begins | `last_scan_at`, `artifact_count_in_window` |
| `librarian.scan.empty` | Scan finds no candidates | `artifact_count_in_window` |
| `librarian.scan.skipped` | Scan cannot run | `reason: archivist_not_present\|memory_path_unresolved\|disabled` |
| `librarian.candidate.proposed` | Proposal written to queue | `proposal_id`, `type`, `classifier_confidence`, `conflict_state` |
| `librarian.candidate.dropped` | Candidate dropped pre-queue | `reason: duplicate\|low_confidence\|classified_null` |
| `librarian.proposal.accepted` | User accepted via skill | `proposal_id`, `final_filename` |
| `librarian.proposal.rejected` | User rejected via skill | `proposal_id`, `reason` (optional) |
| `librarian.proposal.merged` | User chose merge-into-X | `proposal_id`, `merged_into_filename` |
| `librarian.proposal.superseded` | User chose supersede-X | `proposal_id`, `superseded_filename` |
| `librarian.tombstone.created` | A previously-accepted promotion was manually deleted; recorded to prevent re-proposal | `original_filename`, `body_hash` |

---

## Skills

**`/librarian review`** — interactive walkthrough of pending proposals. For each: shows the proposed memory, the source artifact(s), the conflict state and existing memory if applicable, and offers accept / reject / edit / merge / supersede / defer.

**`/librarian calibrate`** — runs the durability filter and classifier against the last N sessions' archivist artifacts (default: 30 days) without writing proposals, and reports precision/recall against a labeled subset. Outputs a recommended `min_classifier_confidence` threshold for the project.

**`/librarian scan`** — manual trigger for the scan pipeline outside of `SessionEnd`. Useful when archivist artifacts have accumulated but no session has ended since librarian was enabled.

---

## Open Questions

1. **Provenance loop with curator.** If curator prunes a librarian-promoted memory and librarian later re-detects the same content, librarian will re-propose. A tombstone mechanism (recording `body_hash` of rejected/pruned proposals) prevents this but introduces its own staleness concerns — when does a tombstone expire?

2. **Cross-clone consistency.** The typed memory store is per-checkout. A promotion made in one clone is invisible to another clone of the same repo. Mirroring promoted bodies (not the full memory store) to `~/.onlooker/librarian/<project-key>/promoted/` would enable cross-clone sync but doubles the write path.

3. **Calibration baselines.** The marker-phrase list is a guess. `/librarian calibrate` is the answer in principle, but it requires a labeled set of "did this artifact deserve promotion?" judgments. The skill can bootstrap by treating any artifact whose summary later appeared in a hand-written memory as a positive label, but that's circular when the typed memory store is sparse.

4. **Memory body authorship.** The classifier writes the proposed memory body. The user may want to edit it before acceptance. The `/librarian review` skill provides edit, but heavy editing implies the classifier output was bad — which calibration the skill should surface (not just the threshold).

5. **Type drift over time.** A `project` memory ("we're rewriting auth for compliance") might become a `feedback` memory once the rewrite is done ("the compliance constraint is why this directory looks weird"). Librarian only assigns type at promotion; curator may need a re-classification capability.

6. **Encoding scheme for `CLAUDE_PROJECT_ENCODED`.** Claude Code encodes the project path by replacing `/` with `-` and prepending `-`. This is a Claude Code internal convention; relying on it makes librarian fragile to encoding changes. A more robust resolution would call Claude Code's own project-resolution logic if exposed.

---

## Non-Goals

- Does not write to the typed memory store without user confirmation by default (see [ADR-001](adr/001-propose-dont-auto-write.md)).
- Does not curate, prune, or audit existing memories — that is curator's job.
- Does not perform retrieval at runtime — that is historian's job for transcripts and the typed memory store's reinjection for distilled facts.
- Does not generate readable session artifacts — that is scribe's job.
- Does not score the *quality* of a promoted memory after the fact — that is curator's domain.
- Does not synthesize cross-session patterns into briefs — that is counsel's job.

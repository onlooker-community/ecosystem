# ADR-001: Two-Tier Staleness Checks — Cheap Every Session, LLM Weekly

- Status: Accepted
- Date: 2026-06-02
- Deciders: Meagan
- Tags: curator, memory, performance, rate-limiting

## Context and Problem Statement

Curator audits the typed memory store for staleness, broken references, contradictions, and decayed dates. The natural place to surface findings is at `SessionStart` — that's when the user is paged in for the day's work and most receptive to a one-line "Curator: 2 findings to review" pointer.

But `SessionStart` fires on every session, including every restart after compaction and every new branch checkout. Whatever curator runs at `SessionStart` runs *a lot*. Two pressures push against each other:

- The checks need to be cheap enough not to delay session startup or accumulate hidden cost.
- The most valuable check (contradiction detection between memory pairs) requires an LLM call per candidate pair, and the candidate set grows with the memory store.

A single check tier — either "all checks every session" or "all checks on a manual trigger" — fails the gradient. The first is too expensive at scale; the second is too easy to forget, and findings rot quietly.

## Decision Drivers

- **`SessionStart` is a hot path.** Cartographer's design explicitly documents that audits run as a detached background process to avoid blocking sessions. Curator inherits the same constraint.
- **Cheap checks are nearly free.** Date pattern matching, file-exists checks on path references, and `rg` calls for symbol references all sit in the millisecond range. They can run every session inside a wall-clock budget without observable latency.
- **LLM contradiction checks scale poorly.** Pairwise comparison is O(N²) on the candidate set even after similarity-filtering. A 100-memory store today may have ~10 candidate pairs; a 500-memory store has more. Running this every session is paying a recurring cost that grows with the user's investment in the system — the worst kind of cost curve.
- **The signal decays slowly.** A contradiction between two memories does not become more or less true between Monday and Tuesday. Weekly cadence captures real changes (new memories, edited memories) without burning compute on a static problem.
- **User-pull beats system-push for big sweeps.** A manual `/curator scan` skill exists for users who want to force a full sweep — that's the right surface for "I just landed a big refactor; re-check everything."
- **Cartographer precedent.** Cartographer runs a periodic background audit and surfaces findings as events. Curator's tiered cadence is the moral equivalent: cheap checks are the "always-on" surface, the LLM sweep is the "periodic" surface.

## Considered Options

1. **One tier: all checks every session.** Simple, predictable, expensive at scale. Wall-clock budget acts as a ceiling but degrades coverage as the store grows.
2. **One tier: all checks on manual trigger only.** Cheap and predictable but loses the always-on signal users want from `SessionStart`. Findings rot.
3. **Two tiers: cheap checks every session, LLM sweep at most once per N days.** Preserves the always-on cheap signal and amortizes the expensive sweep over time.
4. **Three tiers: cheap every session, mid-cost (e.g., rg-based symbol re-check) daily, LLM weekly.** Finer granularity. Adds operational complexity (multiple watermarks, multiple skip-reason cases) without an obvious payoff at current memory-store sizes.
5. **Adaptive cadence.** Run the LLM sweep when the memory store has changed by more than X% since last sweep. Conceptually elegant but introduces a change-detection layer that itself needs validation.

## Decision

We adopt **Option 3: two tiers with a watermark-gated LLM sweep at most once per `llm_sweep_interval_days` (default: 7)**.

The cheap tier runs on every `SessionStart` inside a `wall_clock_budget_ms` budget (default: 500ms). It performs:

- Date pattern parsing and grace-period checks.
- Path reference existence checks.
- Symbol reference `rg` checks (capped at `max_symbol_checks_per_session`).
- Usage tracker reads from the JSONL log (when the `memory.recalled` emitter ships).

If the cheap tier runs over budget, curator emits `curator.scan.skipped` with `reason: "over_budget"` and exits without partial results. The wall-clock budget exists to make budget overruns visible as events rather than as silent slowdowns.

The LLM tier runs only when `now - last_llm_sweep_at >= llm_sweep_interval_days`. The watermark lives at `~/.onlooker/curator/<project-key>/last_llm_sweep.json`. When the gate opens:

- Pairwise Jaccard similarity is computed across all memories.
- Pairs above `contradiction_similarity_threshold` (default: 0.4) with opposing sentiment markers proceed to LLM evaluation.
- Up to `max_pair_evaluations_per_sweep` (default: 50) calls are made, watermark advances regardless of whether the cap is hit.

The manual `/curator scan` skill bypasses both rate gates. Useful for "I just landed N memories; re-check now."

Option 4 was rejected because the user-visible benefit of a third tier is unclear at current memory-store sizes (typically tens of entries, not hundreds). It can be added later without changing the architecture if scale changes the calculus.

Option 5 was rejected as a default because change-detection introduces a calibration problem (what counts as significant change?) on top of the staleness-detection problem. It is plausible as a future optimization layered on Option 3 (e.g., advance the LLM watermark when the memory store has changed by less than a threshold, to defer the next sweep).

## Consequences

### Positive

- `SessionStart` latency stays bounded by the cheap-check wall-clock budget — typically well under 500ms.
- The expensive LLM sweep runs at a cadence that matches the rate-of-change of the underlying signal (memories don't contradict each other on a per-minute basis).
- A manual override (`/curator scan`) gives users the always-available "scan now" surface without making it the default.
- Budget overruns are observable: `curator.scan.skipped` with `reason: "over_budget"` is a leading indicator that the memory store has grown enough to need tuning.
- The watermark-gated sweep also caps cost: a user with a single high-traffic project pays at most N LLM-sweep calls per `llm_sweep_interval_days`.

### Negative

- A contradiction introduced today may go up to 7 days before being flagged. This is the cost of weekly cadence. Mitigation: the manual `/curator scan` exists; users who notice they just added two conflicting memories can force a check.
- The two-tier model is slightly more complex than one tier. Two watermarks (cheap-tier last-run, LLM-tier last-sweep), two budget knobs, two skip reasons. The added complexity is small relative to the cost savings.
- The cheap tier's wall-clock budget interacts badly with very large memory stores. At ≥200 memories, the cheap tier may itself need a per-memory cap (e.g., "scan only memories touched in the last N days"). Not yet a problem; flagged as a future open question.

### Neutral

- The choice of 7 days for `llm_sweep_interval_days` is a guess. Users who care can override. A future calibration could measure how often pair-similarity-with-opposing-sentiment results change verdict between consecutive sweeps; if the rate is low, the interval could grow.

## Implementation Notes

- The cheap-tier wall-clock budget is checked between sub-tasks, not within them. A single `rg` call that itself runs over budget is allowed to finish; the gate prevents *the next* sub-task from starting.
- The LLM watermark is updated *before* the sweep begins, not after. This prevents a sweep that crashes midway from being retried immediately on the next `SessionStart`. The downside: a crashed sweep delays the next full check by the interval. Acceptable — better than a crash-retry loop.
- Findings dedup uses `deduped_hash`. For `contradiction` findings the hash includes both memory bodies' content hashes, so an edit to either body re-opens the finding for re-evaluation on the next sweep.
- Manual `/curator scan` updates the watermark like an automatic sweep — a user who runs the skill on Monday and Tuesday gets two LLM sweeps in two days, which is fine because they explicitly asked for it.
- The cheap-tier and LLM-tier are independently configurable via `cheap_checks.enabled` and `llm_sweep.enabled`. Users can run either tier alone (e.g., LLM sweep off in a budget-sensitive project).

## Validation

- A memory store of ~50 entries should produce cheap-check sweeps under 200ms on a typical macOS dev laptop. If `curator.scan.skipped` with `reason: "over_budget"` fires at this size, the wall-clock budget needs tuning, not the design.
- An LLM sweep at ~50 memories should make ≤20 pair-evaluation calls in the common case. The `max_pair_evaluations_per_sweep` cap of 50 should not be reached. If it is reached regularly, similarity threshold and sentiment-marker filtering need tuning.
- Findings open for more than two LLM-sweep intervals without user action should produce a `curator.finding.aged_unhandled` summary event — an integration point for counsel's weekly brief.

## References

- Cartographer design — precedent for background audits with per-finding events (`plugins/cartographer/docs/design.md`)
- Compass ADR-001 — precedent for explicit budget gates and skip-reason events (`plugins/compass/docs/adr/001-evaluate-prompts-in-context.md`)
- Memory architecture overview (`docs/memory-architecture.md`)
- Curator design (`../design.md`)

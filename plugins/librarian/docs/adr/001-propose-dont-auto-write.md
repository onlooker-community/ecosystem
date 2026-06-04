# ADR-001: Librarian Proposes, Doesn't Auto-Write by Default

- Status: Accepted
- Date: 2026-06-02
- Deciders: Meagan
- Tags: librarian, memory, safety-default, user-confirmation

## Context and Problem Statement

Librarian's job is to consolidate archivist's per-session artifacts into the user's durable typed memory store at `~/.claude/projects/<encoded-project>/memory/`. The typed memory store is reinjected into every future session — anything written there persistently shapes the model's behavior across sessions.

This creates a sharp asymmetry: a missed promotion is silently absorbed (the user just doesn't get a new memory they might have wanted), but a wrongly-accepted promotion is much worse. It silently bloats the memory store, may contradict existing entries, may be reinjected in contexts where it's misleading, and is hard to detect — the model dutifully follows the planted memory without surfacing where it came from. The user only notices when behavior goes subtly wrong over multiple sessions.

The question is whether librarian should write proposals directly to the typed memory store (with curator as a downstream cleanup mechanism), or queue proposals for explicit user confirmation.

## Decision Drivers

- **Asymmetric cost.** False positive (wrong promotion) is silent, slow to detect, and pollutes future sessions; false negative (missed promotion) is recoverable on the next scan or via explicit user request.
- **Promotion is a load-bearing edit.** The typed memory store is part of the system prompt at every session start. Writes to it deserve the same care as writes to CLAUDE.md.
- **Classifier confidence is noisy.** Haiku-grade classification with a small structured prompt is reliable enough for ranking but not reliable enough for unsupervised commits to a high-leverage substrate. Calibration runs in the design doc show meaningful per-repo variation in the precision-confidence relationship.
- **Cartographer precedent.** Cartographer detects issues in instruction files (CLAUDE.md, AGENTS.md) and emits findings — it does not auto-edit those files. The typed memory store is the same kind of substrate (durable, system-level). The same posture applies.
- **Curator is downstream, not a safety net.** Curator catches stale/contradictory memories, but its checks are also heuristic. Relying on curator to undo bad librarian promotions stacks two probabilistic systems and degrades both.
- **User-experience grain.** A "Librarian has 4 pending proposals — `/librarian review`" pointer at session start is a low-cost interruption; a wrongly-promoted memory is a high-cost interruption that arrives later and harder to attribute.

## Considered Options

1. **Auto-promote on high confidence.** Anything classified above a confidence threshold (e.g., 0.85) writes directly to the typed memory store; lower-confidence items go to the proposal queue. Curator catches mistakes.
2. **Always queue proposals (proposed default).** Every promotion goes through the proposal queue. User confirms via `/librarian review` or by setting `auto_promote: true` opt-in.
3. **Stage to a separate "shadow" store first.** Librarian writes to a `~/.claude/projects/<encoded-project>/memory/_librarian_pending/` subdirectory; the user manually moves items into the main store.
4. **No queue — interactive confirmation at promotion time.** Block at `SessionEnd` to walk the user through each candidate immediately. Decisions are made in-the-moment with session context fresh.

## Decision

We adopt **Option 2: always queue proposals; auto-promotion is opt-in via `auto_promote: true`**.

The proposal queue lives at `~/.onlooker/librarian/<project-key>/proposals/<ulid>.json`. At `SessionStart`, librarian injects a single-line pointer indicating proposal count. The user reviews via `/librarian review`, which walks each proposal interactively. Accepted proposals are written to the typed memory store with provenance fields (`source: "librarian"`, `source_session_id`, `source_artifact_ids`, `classifier_confidence`, `promoted_at`). Rejected proposals are logged as tombstones (body hash) so the same content is not re-proposed indefinitely.

Users who explicitly want auto-promotion set `auto_promote: true` in their settings. When auto-promote is enabled, proposals with `classifier_confidence >= auto_promote_threshold` (default: 0.85) are written directly and an `additionalContext` notice surfaces what was promoted, so the user retains visibility even when they opted out of the queue. Conflict-state proposals (duplicate, merge_candidate, conflict_candidate) always queue regardless of auto-promote setting — those need a human disambiguation.

Option 1 is rejected because the asymmetry between false-positive and false-negative cost is too large to bet on a confidence threshold being correctly calibrated on first install. Confidence calibration drifts as model versions change.

Option 3 is rejected because a shadow store complicates the typed memory store's directory shape and is not visible from the model's reinjection — which means the user has to remember to check it. The proposal queue is a better surface for the same goal.

Option 4 is rejected because `SessionEnd` is exactly when the user wants to stop working. Forcing an interactive review at that moment trades a known-bad moment (interruption at the end of work) for a slightly better confirmation surface (fresh context). The cost-benefit favors deferring review to the next session start, where the user is paged for the day's work anyway.

## Consequences

### Positive

- The typed memory store remains under direct user control. Promotions are visible, attributable, and reversible at the moment of promotion.
- The asymmetry between false-positive and false-negative cost is respected — the cheaper failure mode is the default.
- Users who trust librarian after calibration can opt into auto-promotion with a single config key; the design does not penalize the high-trust case forever.
- Provenance metadata is captured at promotion time, which makes curator's downstream job easier: it can use provenance to distinguish librarian-promoted memories from hand-written ones and apply different staleness criteria.
- The default posture matches cartographer's: detect, propose, surface — never silently edit a substrate the user maintains by hand.

### Negative

- The first-run experience is wordier: a user who enables librarian sees "Librarian has N pending proposals" at every session start until they review the queue. Without explicit triage, the queue can accumulate.
- A user with `auto_promote: false` who never runs `/librarian review` gets no benefit from librarian — the proposals pile up unseen, and the typed memory store stays empty.
- The proposal queue is a new substrate with its own state management. Stale proposals (e.g., for memories that have since been hand-written by the user) need to be detected and cleaned.

### Neutral

- Adoption pattern likely mirrors archivist's: opt-in, with a small group of high-trust users flipping `auto_promote: true` after seeing the proposals work well for their projects. The design accommodates both populations.

## Implementation Notes

- The `auto_promote_threshold` defaults to 0.85, deliberately above the calibrated noise floor for the Haiku classifier. The `/librarian calibrate` skill measures per-repo precision at this threshold and recommends adjustments.
- When `auto_promote: true` writes a promotion directly, librarian emits both `librarian.candidate.proposed` and `librarian.proposal.accepted` in immediate succession, with `accepted_via: "auto"` in the latter. This preserves a uniform event trail regardless of acceptance path.
- Conflict-state proposals (`duplicate`, `merge_candidate`, `conflict_candidate`) always queue. The conflict resolution requires user judgment that no confidence threshold authorizes.
- Tombstones (rejection records) are stored at `~/.onlooker/librarian/<project-key>/tombstones/` keyed by body hash. The hash includes the proposed memory's normalized body but not its title or filename, so trivial rewordings of the same rejected content are caught.
- Tombstones expire after `tombstone_ttl_days` (default: 180) so a rejection from six months ago doesn't permanently silence a promotion that would now be wanted. See [librarian design — Open Questions #1](../design.md#open-questions) for the unresolved tradeoff.

## Validation

This decision is validated against the librarian failure modes recorded in the design doc:

- **Failure mode D (pollution from automatic promotion)** is mitigated by default — auto-promote requires explicit opt-in.
- **Failure mode C (memory store starvation)** is mitigated as long as the user runs `/librarian review` at least occasionally. If they never review, librarian provides no benefit; this is acceptable because the alternative (auto-promotion they didn't sign up for) is worse.
- After 30 days of use in a single repo, the ratio of accepted to rejected proposals should fall above 0.7 to indicate the classifier is well-calibrated for the project. A lower ratio is the signal to run `/librarian calibrate` and adjust thresholds.

## References

- Cartographer design — precedent for "detect and propose, do not auto-edit" on durable substrates (`plugins/cartographer/docs/design.md`)
- Compass ADR-001 — precedent for evaluator-substrate decisions being load-bearing (`plugins/compass/docs/adr/001-evaluate-prompts-in-context.md`)
- Memory architecture overview (`docs/memory-architecture.md`)
- Librarian design (`../design.md`)

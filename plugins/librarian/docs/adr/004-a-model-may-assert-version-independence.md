# ADR-004: A Model May Assert Version-Independence

- Status: Accepted
- Date: 2026-09-27
- Deciders: Meagan
- Tags: librarian, lessons, safety-default, unattended, reversal

## Context and Problem Statement

ONL-13 established that only a human may assert a lesson holds regardless of version — that
assertion, plus a unanimous jury, was the guarantee gating anything reaching the shared lesson
pool. The design spec for automatic lesson promotion
(`docs/superpowers/specs/2026-09-26-automatic-lesson-promotion-design.md`, Decision D1) records
the finding that motivates reopening it: two candidates reached a jury in the ONL-107 record,
both human-confirmed (ARG_MAX `01M3FAN035…`, curator `01M3FAKEQK…`), and the jury correctly
rejected both — the adversarial judge caught a version-dependence overreach and a claim the
cited evidence did not actually show. In both observed cases, **the human assertion supplied
ceremony; the adversarial judge supplied the safety.**

Meanwhile every step in the pipeline that costs anything requires that same human to be present:
`confirm` needs an explicit visibility and a hand-written justification, and dispatching the jury
needs a per-run go-ahead. Nothing reaches the pool unless someone is sitting there, even though
the empirical record says the human step isn't what's catching the bad candidates.

The question: should librarian continue to require a human to write the version-independence
justification and greenlight jury dispatch, or can a model supply the justification and the jury
run unattended — provided the risk this removes is replaced by controls that don't require
anyone present?

## Decision Drivers

- The empirical record above: human assertion measured as ceremony, not as the safety mechanism,
  in the only two cases observed so far.
- Cost concentration: every expensive step gates on human bandwidth even though the mechanism
  doing the actual filtering (the jury) does not need a human to run correctly.
- The lesson pool is read by other people and other projects, unlike the memory store ADR-001
  governs, which is local to one project. A reversal here needs *stronger* compensating controls
  than ADR-001's opt-in, not weaker or equivalent ones.
- ADR-002 (agent definitions are shared assets) and ADR-003 (LLM work runs detached) already
  establish that librarian can dispatch named judge agents from a detached worker without a human
  driving the Task tool — the mechanical capability to run a jury unattended predates this
  decision.
- Design spec D7: off by default is non-negotiable given the pool is shared. This mirrors
  ADR-001's `auto_promote` opt-in, but more conservatively — no confidence threshold gates it;
  every model-asserted candidate takes the harder path, full stop.

## Considered Options

1. **No change — human assertion stays mandatory.** Nothing reaches the pool without a human
   writing the justification and approving jury dispatch. Rejected because the record shows the
   human step wasn't the filter — the jury was — so this option pays the full bandwidth cost for
   a safety property it isn't actually supplying.
2. **Let the model assert, judged by the same rubric a human assertion gets, unattended.**
   Cheapest change, but deletes the human ceremony without replacing it with anything — the
   design has no room left to compensate for what ONL-13 was guarding against.
3. **Let the model assert (adopted): judged by a strictly harder rubric selected because a model
   asserted it, published only into a local hold directory behind a veto window, and off by
   default.** Two independent compensating controls stand in for the deleted human step, rather
   than one, and the whole path stays inert until explicitly enabled.
4. **Let the model assert only when a human pre-approves that specific batch (semi-attended).**
   Keeps a human formally in the loop but reintroduces the same bandwidth bottleneck under a
   different name — the design spec doesn't pursue this because it doesn't solve the actual
   problem (nothing moves without someone present).

## Decision

We adopt **Option 3**: a model may write a lesson's version-independence justification, and the
resulting candidate is confirmed and juried without a human present — reversing ONL-13's rule
that reserved that assertion for a human plus a unanimous jury.

This is authorized because the human step ONL-13 relied on was *measured*, not assumed, to be
non-load-bearing: both lessons that reached a jury in the ONL-107 record were human-confirmed,
and the jury rejected both anyway, on grounds (version-dependence overreach; a claim contradicted
by its own cited evidence) that a human confirming a claim in isolation has no particular reason
to catch. Removing the human step removes ceremony that the record shows added no safety in
either observed case.

What replaces it is not "nothing." Two mechanisms that don't require anyone present are selected
specifically by the envelope's `asserted_by` field:

- **A rubric selected because a model asserted it**
  (`librarian_lesson_rubric_id_for_visibility <visibility> model` resolves the `-auto` rubric
  family): same criteria and weights as the human-asserted rubric, every floor raised and the
  pass threshold raised, so a model-asserted candidate is held to a strictly harder bar than a
  human-asserted one at the same visibility.
- **A hold directory and veto window** (`approved_held/`, `shippable_after`, swept at
  `SessionStart`, killable via `lessons veto`) that a human-asserted, jury-passed lesson never
  passes through — that one goes straight to `approved/`. A model-asserted pass is not trusted
  enough to ship immediately even after clearing the harder rubric.

Both are gated behind `lesson_auto.enabled`, off by default (D7): this reversal takes no effect
anywhere until a project explicitly turns it on.

## Consequences

### Positive

- Removes the actual bottleneck the empirical record identified: a good candidate no longer waits
  on a human's bandwidth for a one-sentence justification and a go-ahead that record shows wasn't
  catching the bad candidates anyway.
- The jury — the mechanism actually doing the filtering — runs identically whether attended or
  not (design D2: the auto path reuses the human path's `confirm` and `judge` verbatim, no
  validator changes).
- Two new, specific, testable compensating controls exist where the old design had one diffuse
  one ("a human looked at it"): `test/bats/librarian-lesson-hold.bats` covers the hold/veto
  window, the `-auto` rubric tests cover the harder bar.
- Off by default (D7) means every existing installation is unaffected until a project opts in,
  and the veto window gives even an opted-in project a local, human undo before a lesson reaches
  anyone else.

### Negative

- A human is no longer a checkpoint at all on this path. If the stricter rubric and the veto
  window both fail at once, a bad lesson could reach the shared pool with genuinely nobody having
  looked at it. ONL-13's original guarantee — "a human always looks" — is not weakened on this
  path, it is absent from it; the compensating controls are a different guarantee, not a smaller
  version of the same one.
- `defer` and `unconfirm`, the attended walk's "not now" and "take it back" verbs, do not hold a
  parked, model-eligible candidate against the next unattended scan. A human who uses either verb
  on an opted-in project can have that decision reversed by the next scan, recoverable only
  through the veto window (tracked as a follow-up, not addressed by this ADR).
- Widens the gap between attended and unattended librarian behavior that SKILL.md must now
  describe accurately — the two blanket statements it previously made ("auto-promotion is
  intentionally off," "never dispatch judges without the user's go-ahead") are scoped, in the
  same change that adds this ADR, to state the attended default and name what changes when the
  flag is on, rather than continue to read as unconditional.

### Neutral

- Mirrors ADR-001's shape (opt-in default, compensating surfacing over an outright block) but for
  a strictly higher-stakes surface — the lesson pool leaves the machine; the memory store does
  not — so it is a strictly heavier design, not a repeat of the same one. It deliberately does not
  reuse ADR-001's `auto_promote_threshold` shape: there is no confidence score to threshold on
  here, only a harder rubric and a delay.

## Implementation Notes

- `librarian_lesson_confirm <key> <id> <visibility> <justification> model` is the single call
  both the human walk and the unattended worker share (design D2). It stamps `asserted_by:
  "model"` on the proposal envelope — never on the candidate (design D3), which keeps the
  vendored `lesson-applies-to.subschema.json`'s `additionalProperties: false` scope branches
  intact — and rewrites the scope from `unscoped` to `version_independent`, identically to a
  human's confirm.
- `librarian_lesson_rubric_id_for_visibility <visibility> model` resolves the `-auto` rubric
  family. `librarian-lesson-auto.sh`'s judge dispatch stamps each verdict's `judge_type` from the
  actually-dispatched agent name (`tribunal-judge-standard` → `standard`,
  `tribunal-judge-adversarial` → `adversarial`) rather than trusting the model's self-report in
  its own verdict JSON, so a self-report slip in that field cannot silently make the panel
  `UNJUDGED` forever.
- The jury dispatches `tribunal-judge-standard`/`-adversarial` by name via `claude -p --agent`
  (design D4), never sourcing anything under `plugins/tribunal/` (ADR-002, unchanged by this
  decision).
- All of this runs from `librarian-classify-worker.sh`'s detached stage 6
  (`librarian_lesson_auto_stage`), never on the `SessionEnd` path (design D6, ADR-003).
- `lesson_auto.enabled` defaults to `false` (design D7). `lesson_auto.max_juries_per_scan` bounds
  jury cost per scan; `lesson_auto.veto_window_hours` (default 72) bounds the hold.
- SKILL.md's two blanket statements are corrected in the same change that adds this ADR: they
  remain accurate for the attended walk and for any project with the flag off, and now name what
  changes when `lesson_auto.enabled` is true.

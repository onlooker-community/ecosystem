# Lesson Promotion Pipeline

**Status:** Not started. Design is settled; implementation lives in this repo.
**Tracked by:** `onlooker-97e` in the onlooker beads tracker.
**Authoritative design:** `docs/superpowers/specs/2026-08-08-promotion-pipeline-design.md`
in the [onlooker](https://github.com/onlooker-community/onlooker) repo, Sections 2 and 3.
Read that before making design decisions — this document is orientation, not the spec.

---

## What we are building

A fourth destination for archivist artifacts: a **shared** pool of lessons that
can cross machines and people, rather than the local, per-machine typed memory
store librarian writes to today.

This is easy to misread as "another memory type." It is not. Compare with
[memory-architecture.md](memory-architecture.md):

| | destination | scope | who sees it |
|---|---|---|---|
| librarian → typed memory store | `~/.claude/projects/<encoded>/memory/` | one machine | you |
| **librarian → lesson pool** | `~/.onlooker/librarian/<project-key>/lessons/` | shared, eventually cross-person | you, your org, or the public |

Everything upstream is unchanged. Artifacts are still captured by archivist,
still filtered for durability, still classified, still deduped. The new work
hangs off the end of that existing chain.

## The shape

```
archivist artifacts                      EXISTS  session-scoped facts
 └→ durability filter                    EXISTS  cheap, pre-LLM
    └→ type classifier (Haiku)           EXISTS  user/feedback/project/reference
       └→ conflict/dup detect (Jaccard)  EXISTS  keeps the queue high-signal
          ══════════════════════════════════════
          └→ lesson transform (Haiku)    NEW     claim, rationale, applies_to
             └→ human picks + visibility NEW     propose-only, per librarian ADR-001
                └→ tribunal gate         NEW     one-shot, visibility-scoped
                   └→ approved pool      NEW     local; the sync service drains it later
```

Three new steps, in two existing plugins. **No new plugin.** Librarian already
owns the artifact reader, the durability filter, the classifier, the dedup pass
and the proposal queue — the transform is a fifth stage on a chain that exists,
and its `last_scan.json` watermark already tracks which artifacts have been
considered. A separate plugin would need a second copy of that state, free to
drift.

Tribunal contributes a rubric and reuses `tribunal-judge-security`, which it
already ships disabled by default.

## Why lessons rot, and what the contract does about it

The design exists because of a real artifact in this repo's own storage: a
vitest/vite version-mismatch decision that was true when captured and is false
now. Shared and auto-injected, it would send someone else down a dead end.

So staleness is **structural**, not procedural. A lesson carries version ranges,
and a session outside those ranges simply never matches it. No review queue, no
expiry job, nothing to forget to run. The contract enforces this by construction:
`applies_to.scope` is a tagged union, and the branch that claims version
independence must carry a written justification the tribunal scores. A transform
that failed to infer versions has nothing to put there, so it cannot silently
mint a lesson that never expires.

## The contract

Defined in `packages/lesson-contract` in the onlooker repo and **published as
JSON Schema**:

- `packages/lesson-contract/schema/lesson.schema.json`
- `packages/lesson-contract/schema/counter-observation.schema.json`

Currently `schema_version: 2`.

**The producing side cannot import the definition.** Plugins here are
bash-based and live in a different repo; the zod source is not available to
them. Validate against the published JSON Schema, or simply conform to it. The
sync endpoint in `apps/api` is the real enforcement boundary and validates
regardless, so client-side validation is a convenience, not a trust boundary.

Fields worth knowing before you start:

| Field | Note |
|---|---|
| `claim` / `rationale` | what is asserted, and why it follows |
| `evidence.resolution` | **required.** "this breaks" without "and this fixed it" is a warning, not a lesson |
| `evidence.project_key` | the opaque hash, never the repo name |
| `applies_to.scope` | `{kind: "versioned", versions}` or `{kind: "version_independent", justification}` |
| `applies_to.stack` | every key of `scope.versions` must name an entry here — see cross-field rules below |
| `author_key` | 32 lowercase hex, `HMAC(user_secret, scope)`, derived **per visibility scope** so org and public identities are unlinkable |
| `visibility` | `private` / `org` / `public` |
| `status` | `active` / `refuted` / `superseded` / `retracted`. There is deliberately no `expired` |

**Cross-field rules the schema cannot express**, documented in the contract's
`.describe()` text and enforced at ingest. Worth self-checking before emitting:

- `consensus.agreed <= consensus.judges`
- every key of `applies_to.scope.versions` names an entry in `applies_to.stack`

## What is already decided

Do not re-litigate these; they came out of a full design cycle and are recorded
with reasoning in the spec.

**The gate is one-shot.** `max_iterations: 1`. Below threshold, a candidate is
dropped rather than repaired. Refutation should be cheaper to trigger than
promotion — a wrong lesson actively misleads, a missing one merely fails to
help. Fail toward removal. This also bounds token cost per promotion and stops
the transform learning to satisfy judges rather than the evidence.

**The human confirms before judging, not after.** The transform is Haiku and
cheap; the jury is Opus and not. Splitting the filters this way means the human
judges *intent* ("do I want to share anything about this?"), which only they can
do and which costs nothing, and the jury judges *quality*, which only it can do
and which costs real money. Opus tokens are then only ever spent on candidates
someone already wants shared.

**Gating is scoped by visibility.** Not every lesson passes a jury:

| visibility | gate | why |
|---|---|---|
| `private` | none | you are the only consumer |
| `org` | `lesson-promotion` rubric | the org boundary already implies trust |
| `public` | rubric + disclosure lens | self-reported consensus is gameable by a modified client |

**The rubric**, in tribunal's existing `config.json` shape:

| criterion | weight | `min_pass` | asks |
|---|---|---|---|
| `grounding` | 0.45 | 0.7 | does the claim follow from `evidence` and `resolution`? |
| `scope_accuracy` | 0.35 | 0.7 | does `applies_to` correctly bound the claim? |
| `generality` | 0.20 | 0.6 | is this a lesson, or a session-scoped fact? |

`score_threshold: 0.75`, `gate_policy: majority`, `aggregation_method:
weighted_mean`, `judge_types: ["standard", "adversarial"]` — all tribunal
defaults. The only override is `max_iterations: 1`.

For `public`, add the disclosure lens using the already-shipped
`tribunal-judge-security`:

| criterion | weight | `min_pass` | asks |
|---|---|---|---|
| `disclosure` | 0.30 | **0.9** | leaks a secret or identity, or advocates a harmful practice? |

The high floor is deliberate. Correctness rots and `applies_to` retires it;
harm does not. A leaked credential never expires on its own, so disclosure gets
a floor a strong weighted mean cannot average away.

**State layout**, under librarian's existing project key:

```
~/.onlooker/librarian/<project-key>/
  lessons/approved/<ulid>.json   jury passed; awaiting sync
  lessons/declined.jsonl         artifact_id + lesson_id + verdict + reason
```

The declined ledger matters more than it looks. The watermark advances past a
rejected artifact, so without a record a drop is either silently permanent or —
on a rescan — re-pays Opus tokens to re-judge the same failures every session.
Append-only, never re-judged automatically.

`lesson_id` names the proposal a verdict came from, and is null when there is
none — the transform declines an artifact before any proposal exists. Promote's
double-write guard keys on it so two distinct proposals that share an
artifact_id each get their own row; keyed on artifact_id it dropped the second
verdict silently. `librarian_lesson_seen` deliberately stays keyed on
artifact_id, because it asks a different question: was this *artifact* already
handled?

**"Judged and failed" is not "could not judge."** Only real verdicts go in
`declined.jsonl`. A tribunal API error, or a jury below quorum, leaves the
candidate in proposals untouched. Conflating them lets one transient outage
permanently bury good lessons behind a watermark that has already moved.

## Conventions this repo imposes

From [CLAUDE.md](../CLAUDE.md) — these differ from the onlooker repo:

- **Hooks are bash.** No Python or Node entry points in hook scripts, though they
  may shell out to `node` for event emission or heavy lifting.
- **Event names** follow `<plugin>.<noun>.<verb>`. Likely additions here:
  `librarian.lesson.proposed`, `librarian.lesson.approved`,
  `librarian.lesson.declined`, `tribunal.lesson.judged`.
- **ULIDs, not UUIDs**, and each plugin ships its own helper. Librarian already
  has one — `plugins/librarian/scripts/lib/librarian-ulid.sh`, exposing
  `librarian_ulid`. Use it for lesson ids rather than adding a second generator.
- **Config defaults** live in the plugin's `config.json`; user overrides go under
  the plugin's namespace key in settings. See ADR-004.

## Out of scope

**Counter-observations and re-judgment.** They need consumers of shared
lessons, which needs the sync service and retrieval. The contract already
defines `ZCounterObservation`, and the counter-observation threshold is
explicitly still an open number — do not invent one.

**Publishing anywhere.** The pipeline stops at the local approved pool. Nothing
crosses the network. The sync service drains that queue later, and does not
exist yet.

**The server-side re-judge for public lessons.** Local consensus for public
lessons runs here; the pool records the intended visibility so the server knows
what still needs independent judging.

## Open questions

- **Where the human confirmation surfaces.** Librarian already has a proposal
  queue and a SessionStart surfacer for memory promotions. Reuse it, or keep
  lesson proposals separate so the two kinds of confirmation are not confused?
- **`author_key` derivation.** Resolved: `user_secret` lives at
  `$ONLOOKER_DIR/author/user_secret`, created on first use, never
  project-keyed. See `docs/superpowers/specs/2026-08-12-author-key-design.md`.
- **Whether the transform self-validates** against the published JSON Schema
  before writing to the pool, or leaves all validation to ingest. Validating
  locally catches a bad transform earlier; it also means fetching and caching
  a schema from another repo.

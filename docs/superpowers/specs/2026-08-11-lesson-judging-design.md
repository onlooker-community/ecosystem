# Lesson Judging — Design

**Status:** Approved, not started.
**Tracked by:** `ecosystem-4z8.3`, under epic `ecosystem-4z8`.
**Upstream:** `docs/superpowers/specs/2026-08-10-lesson-confirmation-design.md` (stage 6,
shipped in PR #137) and `docs/superpowers/specs/2026-08-11-lesson-unconfirm-design.md`
(`si6`, shipped in PR #139).
**Blocks:** `ecosystem-4z8.4` (approved pool and declined ledger).

---

## What this stage is

The jury. A human has already said which lesson candidates they want shared and
at what visibility; this stage decides whether each one is good enough to go.

It is the first stage in the pipeline that spends Opus tokens, which shapes
nearly every decision below.

## Where it lives

`/librarian lessons judge`, a new route on the existing librarian skill.
Human-invoked — never a hook.

The agent orchestrates and bash does file I/O, the same split stage 6
established. That split is what lets the jury be real judge subagents rather
than headless `claude -p` calls: tribunal's actual jury runs in its skill via
the Task tool, and only its Stop hook uses the single-prompt shape.

Per candidate, the skill reads the confirmed proposal, spawns the judge
subagents with the candidate and the rubric, parses their verdicts, aggregates
and gates, and **writes the verdict back before moving to the next lesson**.
A new lib function `librarian_lesson_record_verdict <key> <lesson_id>
<verdict_json>` owns that write, surfaced as `librarian_cli lessons
record-verdict <id> <verdict-json> [cwd]`.

The batch comes from `librarian_cli lessons list --confirmed`, which `si6`
shipped precisely because a confirmed lesson was otherwise unfindable.

Before spending anything, the skill reports that batch — how many candidates are
confirmed and how many are public — and asks. A jury is the most expensive thing
in the pipeline, and stage 6 established that the human sees what is about to
happen before it happens. Declining the prompt spends nothing and writes
nothing; every candidate stays `confirmed`.

### There is no Actor

Tribunal's loop is Actor → Jury → Meta-Judge → Gate, built around a producer
that gets retried with critique. A lesson candidate already exists and nothing
rewrites it, so this stage uses only Jury → aggregate → gate.

That makes `max_iterations` vestigial. The bead specified `max_iterations: 1` to
mean *drop, don't repair* — but with no producer, that is simply what happens.
**The knob is omitted rather than carried**, because a setting that reads as if
retry were possible invites someone to raise it later and wonder why nothing
changes.

## Why librarian owns this

CLAUDE.md states that plugins do not call each other directly. This stage
couples librarian and tribunal in some direction no matter how it is arranged:
either librarian reaches for tribunal's rubric and judges, or tribunal reaches
into librarian's project-keyed proposal files and writes verdicts back.

**Librarian owns the verb, the rubrics, and the gate decision, and dispatches
tribunal's judge agents by name.** The invariant is read as forbidding
hook-to-hook runtime calls — the coupling that would make one plugin's failure
another's — not reuse of published agent definitions, which are declarative
assets with no runtime surface. An ADR records that reading.

Keeping it in librarian also keeps the whole lesson lifecycle in one plugin, so
`4z8.4` does not have to split its pool and ledger across two.

## The rubrics

Two builtins in **librarian's** `config.json`, mirroring tribunal's
`rubric.builtins` shape so they stay legible to anyone who knows tribunal, and
so the two could merge later.

| criterion | `lesson-promotion` | `lesson-promotion-public` | asks |
|---|---|---|---|
| grounding | 0.45 / 0.7 | 0.32 / 0.7 | does the claim follow from evidence and resolution? |
| scope_accuracy | 0.35 / 0.7 | 0.24 / 0.7 | does `applies_to` correctly bound the claim? |
| generality | 0.20 / 0.6 | 0.14 / 0.6 | is this a lesson, or a session-scoped fact? |
| disclosure | — | 0.30 / 0.9 | does the text leak a credential, internal name, or proprietary detail? |

*(weight / min_pass.)* Both sum to 1.00. The public rubric is the org rubric
scaled to 70%, with disclosure taking the remaining 30%.

The public weights are rounded **to preserve that sum**, not by rounding each
value independently: `0.35 × 0.7 = 0.245` is written as `0.24`, because rounding
it up to `0.25` totals 1.01. Use the values in the table verbatim rather than
recomputing them.

The sum matters even though nothing reads it today: tribunal validates each
weight in `[0,1]` but never checks their total, so an unnormalized 1.30 would
silently mis-score the moment real `weighted_mean` lands.

`score_threshold` 0.75 and `judge_types` `[standard, adversarial]` for both.

### scope_accuracy is the point of the whole pipeline

Stage 5 was deliberately restricted to emitting `versioned` scope, because a
model minting `version_independent` lessons produces claims that never expire.
Stage 6 handed that branch to a human, who has the context to write a real
justification, and refused it at `private` because that tier runs no jury.

`scope_accuracy` is where the loop closes. The schema guarantees a
`version_independent` lesson **carries** a justification; this criterion asks
whether it is **true**. Schema stops the accident; the jury stops the lazy
excuse.

### The weights and floors are inert today

`tribunal_aggregate` takes the rubric as a parameter and explicitly discards it;
`weighted_mean` falls through to the same plain average as `mean`. And
`min_pass` is enforced nowhere — `TribunalVerdictPayload` carries one scalar
`score`, one boolean `passed`, and `criteria_evaluated` as a list of *names*
with no scores, so the orchestrator never learns what a judge scored on any
individual criterion. Per the judge contract, `passed` is the judge's own
self-assessment against the thresholds: prompt-level, not machine-enforced.

The weights and floors are declared anyway, because they are the honest
statement of intent and they go live unchanged the moment `ecosystem-pht`
implements threading. But no part of this design may depend on them.

## Gating by visibility

| Visibility | Jury | Rubric | Gate policy |
|---|---|---|---|
| `private` | none — no model call at all | — | — |
| `org` | standard + adversarial | `lesson-promotion` | majority |
| `public` | standard + adversarial | `lesson-promotion-public` | unanimous |

`private` skipping the jury entirely is what makes "cost scales with intent
rather than artifact volume" true end to end, and it is why stage 6 refuses
`version_independent` at `private` — that is the tier with nothing checking the
claim.

`org` gets the rubric alone because the org boundary already implies trust.

`public` gets **`unanimous` instead of `majority`**, and this is a deliberate
substitution for a mechanism that does not exist. The intent was a disclosure
floor at `min_pass` 0.9 — a near-veto, on the reasoning that correctness rots
and `applies_to` retires it, but harm does not; a leaked credential never
expires on its own. Since `min_pass` cannot be enforced, `unanimous` delivers
the property that actually mattered: **a single judge's objection cannot be
outvoted.**

The trade-off is stated plainly: it is not disclosure-specific. A judge unhappy
about `generality` also blocks a public lesson. That is accepted for the tier
that leaves the machine and draws the disclosure lens. When `pht` lands, this
can narrow to a true per-criterion floor.

### No new judge agent

The bead proposed reusing `tribunal-judge-security` as the disclosure lens. On
inspection that does not work: it is built for code review — injection, auth
bypass, path traversal, SSRF, TOCTOU — and is instructed to *read the changed
files*, with `Read, Grep, Glob` as its tools. A lesson candidate is prose and
has no files.

Disclosure is therefore a **criterion** scored by the judges already empaneled,
not a judge type. If generalist judges prove weak at it, a purpose-built
disclosure judge is the follow-up — but writing one now is machinery ahead of
evidence.

## Verdict is not the same as "could not judge"

`4z8.4` draws this distinction; this stage has to produce it.

Tribunal's own skill tells the orchestrator that an unparseable judge response
becomes `score: 0, passed: false` and lets the gate decide. **For lessons that is
inverted deliberately.** A flaky judge would permanently decline a good lesson,
and the watermark has already advanced past its artifact — so one transient
outage would bury it for good.

**Every empaneled judge must return a parseable verdict, or the candidate is
unjudged.** Same for `claude` being unavailable, a judge timing out, or an empty
panel. There is no quorum rule to tune: with a two-judge panel under `unanimous`
or `majority`, losing one verdict means the gate cannot be decided at all, so
"all of them" is the only honest threshold.

**"Unjudged" is expressed as the absence of a write.** The proposal stays
`confirmed`, nothing lands on disk, and the next run retries it. There is no
failure state to clean up. The skill reports which candidates it skipped so the
human knows to re-run.

## State model

`confirmed` → `approved` | `rejected`, written atomically per lesson.

Committing per lesson rather than per batch is what makes a crash cheap: each
candidate transitions the moment its own verdict lands, so an interrupted run
costs at most one re-judgment and strands nothing.

**No `judging` status.** `si6` deferred that decision here, and the answer is no.
A mid-flight status would recreate exactly the trap `si6` was filed to fix — a
lesson stuck in a state with no verb to free it, needing its own recovery
escape hatch. Per-lesson commit gets crash-safety without one.

Alongside `status`, the write records `judged_at` and a `verdict` object: rubric
id, gate policy, aggregate score, threshold, the per-judge verdicts, and a
reason when blocked.

**A rejected proposal keeps its file**, exactly as a passed one does. That is
what stops the artifact being re-proposed on the next scan and re-paying tokens
for an answer already given.

### `unconfirm` needs no change

Its catch-all refuses any status it does not recognize, naming it — so
`approved` and `rejected` are refused automatically, with no coordination
between the stages. This is the forward-safety promise `si6` made to this stage,
and collecting it costs nothing. It is asserted with a test rather than trusted.

Undoing a rejection is **out of scope**, for the same reason undoing a `pass`
was: it is a real decision with its own record, and inventing a reversal verb
for it now would repeat the mistake `si6` avoided.

## Events

None, consistent with the two stages before it. `@onlooker-community/schema`
2.11.0 registers only `meridian.lesson.curated` — no `librarian.lesson.*` and no
`tribunal.lesson.judged` — and the runtime emitter exits 1 on an unknown
`event_type`. `4z8.4` reads proposal files, not the bus.

## Testing

bats, isolated temp home, per the repo's `writing-tests` skill — single-bracket
assertions or `|| return 1` on non-final ones, and every new assertion broken
once to confirm it discriminates.

- **A `private` candidate reaches `approved` with no model call**, asserted with
  a `claude` stub on `PATH` that fails loudly if invoked — the technique that
  already proved stage 5's `unavailable` path and stage 6's no-model guarantee.
- `org` uses `lesson-promotion` with majority; `public` uses
  `lesson-promotion-public` with unanimous.
- **A public candidate that one judge blocks is rejected even when the aggregate
  clears `score_threshold`** — the unanimous property, and the reason this tier
  differs at all.
- One judge returning unparseable output leaves the candidate `confirmed` with
  nothing written, and the skipped id is reported.
- A below-threshold candidate is rejected and keeps its file.
- `unconfirm` refuses `approved` and refuses `rejected`, naming the status.
- Re-running skips candidates that are not `confirmed`.
- Both rubrics' weights sum to 1.00 — a guard for when `pht` makes them live.

## Out of scope

The approved pool and `declined.jsonl` writes (both `4z8.4`), `author_key`
derivation (`4z8.5`), any sync, and re-judging a rejection. Per-criterion score
threading and real `min_pass` enforcement are `ecosystem-pht`, filed against
tribunal.

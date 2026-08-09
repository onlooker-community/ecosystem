# Lesson Transform — Design

**Status:** Approved, not started.
**Tracked by:** `ecosystem-4z8.1`, under epic `ecosystem-4z8`.
**Parent design:** `docs/superpowers/specs/2026-08-08-promotion-pipeline-design.md` in the
[onlooker](https://github.com/onlooker-community/onlooker) repo, Sections 2–4.
That document governs the pipeline. This one covers stage five only, and where
the two disagree, the disagreements are called out explicitly below.

---

## What this stage is

Librarian's fifth stage. It reads one durable, classified, deduped archivist
artifact and emits a **lesson candidate** — the subset of a Lesson that can be
inferred from an artifact.

It is not a Lesson. `lesson.schema.json` v2 requires thirteen fields; this stage
owns four:

| Field | Owner |
|---|---|
| `claim`, `rationale`, `evidence`, `applies_to` | **this stage** |
| `visibility` | the human, at confirmation (`4z8.2`) |
| `consensus` | the jury (`4z8.3`) |
| `id`, `schema_version`, `source`, `status`, `superseded_by`, `author_key`, `promoted_at` | the pool write (`4z8.4`) |

Keeping that split explicit is what stops a stage inventing a field it does not
own. It also answers the open question the epic carried: the transform *cannot*
validate against `lesson.schema.json`, because the object is deliberately
incomplete at this point.

## Decisions

Four decisions were settled during design. The first and third depart from the
parent spec; both departures are argued below rather than assumed.

**1. No recoverable resolution means declined.** `evidence.resolution` is
required with `minLength: 1`, and the archivist artifact shape has no resolution
field — it must be inferred from prose. When it is not there, the artifact is
declined. This preserves the contract's stance that "this breaks" without "and
this fixed it" is a warning, not a lesson.

**2. Validation is against vendored sub-schemas**, not the full lesson schema,
and with no network access at runtime. See *Validation* below.

**3. The transform emits `versioned` only.** It can never emit
`version_independent`. If it cannot infer versions, the artifact is declined.

The parent spec allows either branch and relies on the jury's `scope_accuracy`
criterion to catch a lazy justification — "the schema stops the accident, the
jury stops the lazy excuse." That defense has a hole: **private lessons run no
jury at all.** A weakly-justified `version_independent` candidate marked private
reaches the pool with nothing checking it, and a lesson with no version bound
never expires.

That is precisely the motivating failure. The stale vitest artifact was a
private, local memory that misled its own author across sessions. Closing the
branch at the transform makes the guarantee structural at every visibility tier
instead of relying on a gate the private tier skips. `version_independent`
becomes an explicit human choice at `4z8.2`, made by someone with the context to
write a justification that is actually true.

**4. A cheap pre-gate runs before the model.** Mirrors librarian's existing
pre-LLM durability filter.

## Architecture

New file: `plugins/librarian/scripts/lib/librarian-lesson-transform.sh`, sourced
by the existing `librarian-session-end.sh` chain and running after conflict/dup
detection. No new hook. No new plugin — librarian already owns the watermark,
and a second copy of that state would be free to drift.

### Storage

```
~/.onlooker/librarian/<project-key>/lessons/
  proposals/<ulid>.json    this stage
  approved/<ulid>.json     4z8.4
  declined.jsonl           4z8.4 (but see Boundary changes)
```

Lesson state lives in its own subtree rather than reusing librarian's existing
`proposals/` directory. The two carry different consequences: a memory promotion
writes to your machine, a lesson proposal is a step toward publishing beyond it.
`4z8.2`'s open question is specifically the risk of users confusing the two, and
separate trees mean a confirmation surface cannot merge them by accident.

Each candidate carries its source `artifact_id` at the top level, which is
load-bearing for idempotency.

Use `$ONLOOKER_DIR`, never a hardcoded `~/.onlooker`, so the test suite's
isolated temp home is respected.

## The three steps

### 1. Pre-gate (bash, free)

`librarian_lesson_pregate <artifact_json>` scans `summary` and `detail` for a
version-shaped token (`\d+\.\d+`, `v5`, `5.x`).

Because `versioned` is the only branch this stage can emit, an artifact with no
version token anywhere cannot produce a valid `scope.versions`. Rejecting it is
a fact about the output shape, not a quality heuristic. The pre-gate rejects
nothing else — "does this have a resolution" is semantic and stays with the
model, because a keyword regex would silently drop good candidates.

Pre-gate rejections are silent: no event, no ledger entry. `declined.jsonl`
exists to make expensive drops auditable and to keep re-runs cheap. Re-running a
regex is free, so recording it would dilute the signal `4z8.4` wants for rubric
tuning.

### 2. Model call

Mirrors `librarian-classifier.sh`: `claude -p --max-turns 1`, model, temperature
and max-tokens from config, a hard wall-clock timeout so SessionEnd cannot hang,
fail-soft to empty string, markdown fences stripped before parsing. The timeout
follows the classifier's ceiling of 20 seconds per call, and like the classifier
it falls back through `timeout`, `gtimeout`, then no timeout when neither exists.

The prompt supplies the artifact in a delimited block and requires one of two
responses: a candidate object, or an explicit refusal carrying a reason
(`no_resolution` or `no_versions`). A refusal is a real answer and must be
distinguishable from a failed call.

Config lives in the plugin's `config.json` under
`librarian.lesson_transform.{model, temperature, max_output_tokens,
timeout_seconds}`, read via `librarian_config_get` from the caller, with user
overrides under the plugin namespace key per ADR-004. There is no `enabled`
flag — that option was removed repo-wide in #108.

### 3. Validation

Two layers, because **ajv is not available at runtime**. It resolves in dev and
CI only; installed marketplace plugins ship no `node_modules` (ADR-005).

- **Runtime:** dependency-free `jq`, which works everywhere.
- **Source of truth:** sub-schemas vendored at
  `plugins/librarian/schema/lesson-evidence.subschema.json` and
  `lesson-applies-to.subschema.json`, extracted from the published
  `lesson.schema.json`.
- **Tests:** assert the `jq` validator and the vendored sub-schema agree over a
  corpus. The parent spec sets this precedent directly — the two mechanisms were
  "proven able to disagree," so they are asserted separately.
- **CI:** a drift guard fetches the published schema from `schema.onlooker.dev`
  and compares the vendored copies, matching how schema drift is already caught.

The version-range pattern is where this earns its keep. The schema accepts `<6`,
`<=6`, `=6`, `>4`, `>=4`, and two-sided `>=4 <6`. It **rejects** npm-style
`^5.4.21`, `~5`, `5.x`, and bare `5.4.21` — which are exactly what a model
reaches for by default.

It also rejects `>=0`, `>=0.0`, and `>=0.0.0` by construction. An unbounded
lower bound is version-independence wearing a costume: it matches every session
and never expires. That closes the same hole decision 3 closes, one layer down.

Plus the cross-field rule JSON Schema cannot express: every key of
`scope.versions` must name an entry in `applies_to.stack`.

## Failure taxonomy

Two categories look identical from the call site — both produce no candidate —
and conflating them is the sharpest risk in this stage.

| Condition | Outcome |
|---|---|
| pre-gate: no version token | silent skip, nothing written |
| model returns unparseable JSON | declined, `transform_invalid` |
| model refuses: no resolution | declined, `no_resolution` |
| model refuses: cannot infer versions | declined, `no_versions` |
| candidate fails sub-schema validation | declined, `schema_invalid` |
| `versions` key not named in `stack` | declined, `schema_invalid` |
| `claude` CLI absent | **untouched**, no ledger entry |
| timeout, or empty response | **untouched**, no ledger entry |

A verdict says "this artifact cannot become a lesson." An outage says "we could
not tell." Recording an outage as a verdict buries a good artifact permanently,
because the watermark has moved past it and declined entries are never re-read.

## Idempotency

**The watermark cannot provide it.** `last_scan.json` is `{scanned_at: <ISO>}` —
a wall-clock timestamp stamped at scan time, not an artifact-id set. The parent
spec's failure table states that the watermark, ledger and pool are "all keyed
by `artifact_id`"; that is true of the ledger and pool but not the watermark.

Before spending a model call, skip when the `artifact_id` already appears in
`lessons/proposals/`, `lessons/declined.jsonl`, or `lessons/approved/`. That
check is what actually delivers "the same artifact cannot be promoted twice" and
"re-runs are cheap."

Librarian's existing tombstones do not help here: they are keyed by body hash
with a 180-day TTL, built for "the user rejected this memory, stop offering it."
Lesson idempotency must be artifact-keyed and permanent.

## Testing

bats, using the repo's isolated-temp-home helpers.

**The parent spec's acceptance test inverts.** It designates artifact
`01KZ45MKAM734ZS7JK24D2DK0R` — the real vitest/vite mismatch — and expects it to
transform to `kind: versioned` with `{vite: "<6", vitest: ">=4"}`. Under decision
1 it cannot: the artifact records only that the mismatch is real, and its session
ended with an open question titled "What is the correct fix for the vitest/vite
version mismatch?" No resolution was ever found. Neither does its later
refutation artifact (`01KZEAF9EY4C6TTR0V7YFN9VYJ`), which says the claim was
disproven without stating what is true.

So it becomes the **negative** test: declined, `no_resolution`. The artifact that
motivated the whole design proves the resolution rule fires.

The positive test uses a synthetic fixture, since no artifact on disk carries
both a resolution and versions. Shape it like the vitest case so it still
asserts `{vite: "<6", vitest: ">=4"}`.

Also:

- validator agreement over a range corpus — `^5.4.21`, `~5`, `5.x`, `5.4.21`,
  `>=0`, `>=0.0.0` must all fail; `<6`, `>=4`, `>=4 <6`, `=6` must pass
- infrastructure is not a verdict: with `claude` absent, nothing is written to
  `declined.jsonl` or anywhere else. This is the test most likely to regress
  silently
- idempotency: an `artifact_id` already in `declined.jsonl` triggers no model call
- cross-field: a `versions` key absent from `stack` is declined
- pre-gate: an artifact with no version token produces no ledger entry

## Events

`librarian.lesson.proposed` and `librarian.lesson.declined`, emitted through
`scripts/lib/onlooker-event.mjs`. Both must be registered in
`@onlooker-community/schema` before they are emitted.

## Boundary changes to sibling issues

Building this stage first has two consequences for the issues around it:

- **`4z8.4`** currently owns `declined.jsonl` and its append function. The
  transform produces declines, so the storage primitive moves here and `4z8.4`
  reuses it.
- **`4z8.2`** gains the `version_independent` path from decision 3, including
  where a human writes and edits the justification.

## Out of scope

Version inference from anything but artifact prose. Reading the project's
current `package.json` or lockfile would report today's versions, not the
versions in effect when the problem was observed — and the gap between those two
is the entire staleness problem this pipeline exists to solve.

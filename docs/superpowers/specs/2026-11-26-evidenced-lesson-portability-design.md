# Evidenced Lesson Portability

- Status: Draft, for review
- Date: 2026-11-26
- Owner: Meagan
- Supersedes: `plugins/librarian/docs/adr/004-a-model-may-assert-version-independence.md`
  (on acceptance, as a new librarian ADR-005)
- Replaces: ONL-311's self-check (`2026-11-24-lesson-self-check-design.md`)
- Related: ONL-198 (the `lesson_auto` review), ONL-307 (correcting a lesson at confirm)

## Summary

A lesson becomes portable because evidence shows it travels, not because a
model or a person argues that it does. Knowledge that is true in one project
goes to the typed memory store, which already exists and works. Lessons
carry the exact tool versions they were observed on, read mechanically from
the project, and reach the shared pool by one of two ways in: a person
nominates one, or the same lesson recurs in a second project.

Nothing in the portable path asserts version independence any more. That
assertion is the step every failure so far has come through.

## Problem

### What the store shows

Across 11 projects, on 2026-11-26:

| Outcome | Candidates |
|---|---|
| Passed or declined by a person, unscoped | 102 |
| Pending, unscoped | 53 |
| Rejected by the jury | 45 |
| Approved | 12 |

Six of the seven model-asserted approvals were later vetoed by hand, so about
216 candidates have produced 6 lessons that stand. Only 7 candidates were
ever scoped to versions. Every other candidate either waited for a person or
was argued to hold regardless of version.

### Why the argument fails

The vetoed lessons are true and useful in the project they came from:
"historian reports both query lengths", "export CLAUDE_SESSION_ID in skill
Setup blocks", "batch emit-batch at SessionStart". Each was given a
universal justification to clear the version-independence bar, and the
justification defended a nearby principle instead of the claim.

ONL-311 tried to catch that with a second model call. Three attempts on the
same 11 lessons (`plugins/librarian/docs/measurements/2026-11-24-self-check/`):

| | Attempt 1 | Attempt 2 | Attempt 3 |
|---|---|---|---|
| Vetoed lessons failed (want at least 5 of 6) | 6 | 5 | 3 |
| Approved lessons failed (want 0 of 5) | 5 | 3 | 4 |

Every wording that caught the vetoed lessons also failed approved ones,
because almost any honest version-independence argument rests on a rule
that covers other claims too. One lesson flipped between runs with its check
unchanged, so single samples are also noisy. The question being asked has no
reliable answer from a model, so this design stops asking it.

## Decisions

### D1. Memory is the local tier

Project-specific knowledge is a project memory, not a lesson. Lessons are
for knowledge that travels. A candidate a person keeps local is written as a
memory proposal through the existing ADR-001 path, so nothing new stores
local knowledge.

### D2. Versions are observed, not claimed

Each lesson records `evidence.observed_on`: the exact version of each stack
entry at the commit the session ran on. The scope is then derived from it by
a fixed rule (D4), with no model call. A lesson says "seen on these
versions", and retrieval matches it against sessions on compatible ones.

### D3. `stack` lists tools; topics go in `topics`

The transform currently puts concepts in `stack` ("CSS", "testing",
"rate-limiting"), because nothing tells it not to. Concepts have no version.
`stack` is restricted to things with a version (a package, a CLI, a service,
a component), and a new `applies_to.topics` holds the rest. A lesson whose
stack is empty depends on no tool and takes the scope kind `no_stack` (D5).

### D4. A fixed rule turns an observation into a range

For an observed version `X.Y.Z`:

- `X >= 1`: `>=X.Y.Z <X+1`, the rest of the same major.
- `X == 0`: `>=0.Y.Z <0.Y+1`, the rest of the same minor.
- A version that doesn't parse as at least `X.Y` (BSD awk's `20200816`)
  stays in `observed_on`, and the entry is left out of `scope.versions`. No
  range is invented for it. It does not go in `unresolved`, which is only
  for entries no source could version (D6). Evidence records what was
  observed. Whether a range follows from it is computed when needed, so the
  rule can change later without rewriting stored lessons.

This leans on semver's promise, which is the same promise a person relies on
when they upgrade within a major. A lesson that breaks within a major is a
defect for the jury's grounding check, not something to guard against
everywhere.

### D5. The scope union gains `no_stack` and keeps `versioned`

`ZScope` (onlooker `packages/lesson-contract/src/applies-to.ts`) becomes:

- `versioned`: unchanged. Its ranges now come from D4 rather than the model.
- `no_stack`: new. Valid only when `applies_to.stack` is empty, which ingest
  checks as a cross-field rule beside the existing `versions`-key rule in
  `apps/api/src/lessons/rules.ts`. It needs no justification because the
  claim is checkable: there is nothing in the stack to have a version.
- `version_independent`: kept so existing pool entries still parse.
  Librarian stops producing it.

### D6. Unresolved entries are visible and keep a lesson local

`evidence.unresolved` lists stack entries no source could version. A
candidate with any unresolved entry can't take the recurrence way in. It can
still be nominated, and the person supplies the version, or a date for a
hosted service.

### D7. Two ways in to the portable tier

1. **Nomination.** In `/librarian lessons`, a person nominates a candidate.
   It goes to the attended jury, as a human-confirmed lesson does today,
   with no justification to write.
2. **Recurrence.** A candidate whose claim matches a candidate in a
   different project is eligible for the unattended jury, provided both
   resolve fully. It is still held for the veto window.

Neither way in involves a model asserting anything about versions.

### D8. The jury judges wording, grounding and scope accuracy against evidence

The rubric keeps its criteria. `scope_accuracy` is redefined from "does the
justification support version independence" to "does the claim stay within
what `observed_on` and the cited evidence show". This is the one per-lesson
model spend left on the portable path.

### D9. Retire the version-independence assertion

Removed: the `unscoped` transform mode's "a human will decide whether this
holds regardless of version", `librarian_lesson_auto_justify` and its
fingerprint and refusal records, and the self-check from ONL-311, which is
never merged. `lesson_auto` keeps only its unattended jury dispatch, now fed
by recurrence. ONL-198's review becomes a review of that.

## Components

### Observe: `plugins/librarian/scripts/lib/librarian-lesson-observe.sh`

One function, `librarian_lesson_observe <project_key> <observed_at> <stack_json>`,
prints `{observed_on: {...}, unresolved: [...]}`. It needs no model and is
deterministic for a given repo state, so bats can cover it fully. Sources, in
order:

1. **The project's manifests, at the session's commit.** The commit is
   `git rev-list -1 --before=<observed_at> HEAD` in the repo the project key
   resolves to. The files are read with `git show <commit>:<path>`, never
   from the working tree:
   `package-lock.json`, `pnpm-lock.yaml`, `package.json` (only as a fallback,
   since it holds a range), `mise.toml`, `Cargo.lock`, `go.sum`,
   `Gemfile.lock`, `uv.lock`, `.github/workflows/*.yml` (`uses: x@vN`), and
   `wrangler.toml` (`compatibility_date`).
2. **Own components.** `plugin.json` or `package.json` with a matching
   `name`, looked up in the repo that owns the component. This uses the same
   project-key map the resolution measurement built.
3. **A probe allowlist,** run in the detached transform and never at
   SessionEnd: `bash`, `git`, `awk`, `grep`, `sed`, `node`, `npm`, `sqlite3`,
   `jq`, plus `uname -sr`. A probe records the flavor where there is one
   (`awk: "bsd 20200816"`, `sed: "gnu 4.9"`). Because the probe sees the
   machine at transform time, not session time, its entries carry
   `"source": "probe"` so the jury can weigh them.

Each name is matched after lowercasing and stripping a `.js` suffix, the
same normalization the measurement used.

### Transform changes: `librarian-lesson-transform.sh`

- The prompt says `stack` holds only things with a version and `topics`
  holds concepts, with examples from the store's unresolved list.
- The model no longer writes a scope in either mode. The transform calls
  Observe and derives scope by D4 and D5.
- The `no_versions` refusal goes away, because no version is asked for. The
  `no_resolution` refusal stays.

### Review: `librarian-lesson-review.sh`, `librarian-cli.sh`, `SKILL.md`

The per-candidate actions become:

| Action | Effect |
|---|---|
| nominate `<visibility>` | Goes to the attended jury. Any `unresolved` entries are asked for first. |
| keep local | Writes a memory proposal from the claim and rationale, and accepts it, since the person is present. Retires the candidate. |
| pass | As today. |
| defer | As today. |

`confirm` and its justification prompt are removed. The ONL-307 question of
whether a person can correct a lesson's wording fits here as an edit-before-
nominate step, but stays out of scope for this design.

### Recurrence: `librarian-lesson-recur.sh`

- At transform, embed the new candidate's claim with the embedder historian
  already uses, and store the vector on the proposal.
- Compare it against stored candidates in other project keys. A match is
  cosine similarity at or above `librarian.lesson_recur.threshold`, which
  has no default until a measurement sets one.
- A match records `recurred_in: [<project_key>...]` on both proposals and
  emits `librarian.lesson.recurred`.
- If ollama is down, the transform stores the candidate without a vector,
  as historian does, and a later backfill embeds it.

The flag is `librarian.lesson_recur.enabled`, off by default. It turns on
after the threshold measurement (Testing).

## Data changes

| Where | Change |
|---|---|
| onlooker `lesson-contract` `ZAppliesTo` | Adds `topics: string[]` |
| onlooker `lesson-contract` evidence | Adds `observed_on: Record<string, {version, source}>` and `unresolved: string[]` |
| onlooker `lesson-contract` `ZScope` | Adds `{kind: "no_stack"}` |
| onlooker `apps/api` rules | Adds the cross-field rule that `no_stack` requires an empty stack |
| `@onlooker-community/schema` | Adds `librarian.lesson.recurred` and `librarian.lesson.kept_local`, and removes the justify-path payload fields once retired |
| librarian promote key set | Carries `topics`, `observed_on` and `unresolved` through, since `ZLesson` is strict |

The contract changes land first, in the onlooker repo, because
`ZLesson` is strict and an unknown key fails ingest.

### Existing data

- **53 pending candidates:** re-run Observe on them, then walk them in
  `/librarian lessons` with the new actions. Their stack keeps its topics
  until a re-transform, which is optional.
- **Approved or shipped lessons:** left alone. They still parse.
- **`declined.jsonl` and `passed.jsonl`:** unchanged.

## Error handling

- When Observe can't find the repo for a project key, every entry is
  `unresolved` and the candidate stays local. It never fails the transform.
- When `git rev-list --before` finds no commit, it falls back to HEAD and
  records `"basis": "head"`.
- A probe that exits non-zero or prints nothing leaves the entry
  `unresolved`.
- None of this runs at SessionEnd. The transform is already detached
  (ADR-003), so the 1.5s ceiling doesn't apply.

## Testing

- **Observe:** bats with fixture repos for each manifest kind, read at a
  past commit so a working-tree edit isn't picked up. Covers own components,
  the probe with a stubbed `bash --version`, and the 0.x and non-semver
  rules in D4.
- **Transform:** the existing stubbed-`claude` tests gain a stack-and-topics
  case and lose the scope assertions, since the model no longer writes scope.
- **Contract:** vitest in onlooker for `no_stack`, plus the cross-field rule
  at ingest.
- **Measurements before turning anything on:**
  1. **Resolution.** Re-run the 2026-11-26 measurement with Observe. The
     baseline is 83 of 215 candidates (39%) fully resolved. The estimate with
     all three sources and the topics split is 60–70%. It costs nothing.
  2. **Recurrence threshold.** Embed the store's claims and hand-label the
     pairs above several candidate thresholds. The threshold is the lowest
     one with no false matches among the labeled pairs. Only the embedder
     runs, so it costs nothing.

## Rollout

Each piece ships as its own PR, in order:

1. The contract changes (onlooker) and the schema registrations.
2. Observe, alone, with its measurement committed.
3. The transform changes, and the promote key set.
4. The review actions, the removal of `confirm`, and ADR-005.
5. The retirement of the justify path and the self-check (D9).
6. Recurrence, behind its flag, with its threshold measurement.

The 53-candidate walk happens after step 4.

## Success

- At least 60% of new candidates resolve fully (Observe's measurement).
- A person walking the queue spends nothing on version arguments: no
  justification prompt, no `scope.kind` decision.
- Vetoes of shipped lessons, measured the way ONL-198 counts them, stay
  under ADR-004 criterion 3's 25% ceiling over the first 20 jury decisions.
- Local knowledge that used to be passed or declined reaches memory instead.
  This is counted as `librarian.lesson.kept_local` events.

## Open questions

1. **Flavor in retrieval.** `observed_on` can say `awk: "bsd 20200816"`, but
   a range can't express BSD versus GNU. Should the probe name the tool by
   flavor in `stack` (`bsd-awk`), or should retrieval learn to read flavor?
2. **Hosted services.** Is a `compatibility_date` or an action's `@v4`
   enough to version Cloudflare Workers or release-please, or should those
   stay `unresolved` until nominated?
3. **ONL-198.** With the justify path gone, does the review of `lesson_auto`
   still run on 12-07 against the old criteria, or wait for recurrence to
   produce unattended verdicts?

# A Project Dimension on the Event Envelope — Design

**Status:** Approved, not implemented.
**Tracked by:** [ONL-129](https://linear.app/onlooker/issue/ONL-129) (`ecosystem-hscz3o`).
**Closes on landing:** [ONL-9](https://linear.app/onlooker/issue/ONL-9) (`ecosystem-449.71`).
**Batched into the same schema release:** [ONL-7](https://linear.app/onlooker/issue/ONL-7)
(`ecosystem-449.38`).
**Found already shipped while writing this spec:** [ONL-10](https://linear.app/onlooker/issue/ONL-10)
(`ecosystem-449.39`) — see [Already done](#already-done).
**Scope:** schema 2.28.0, the ecosystem emitter and its project-key libs, and the hosted
summarizer up to the point the dimension lands in `session_summaries`. The web view is not
in scope — see [Out of scope](#out-of-scope).

---

## Why

Every canonical event is attributable to a machine and a session, never to a repository. So
the hosted side cannot answer "which repo?" about anything — the most natural axis for a
developer-facing dashboard, and the axis bursar already computes locally and cannot surface.

A project key *is* present today, but only inside `payload`, and only for five plugins. Of
218,738 events measured locally, ~47,000 (21%) carry one. The other 79% — all of `session.*`,
`tool.*`, `curator.*`, `historian.*`, `librarian.*`, `assayer.*`, `governor.*`, `echo.*`,
`tribunal.*` — carry nothing.

And payloads never cross into the hosted side. That is a designed guarantee, not an oversight.
`apps/cli/src/sessions.ts` says so in its own docstring:

> The envelope only. `payload` is absent from `EventEnvelope` deliberately, and that absence is
> the feature's entire safety story: a plugin shipping a new event type cannot leak through this
> path, because no code here reads what its events contain.

So the project key that does exist is structurally unreachable from the web app. This is not a
summarizer change. The dimension has to be promoted into the envelope.

The local join is lossy too: `~/.onlooker/session-trackers/<session_id>` carries `cwd`, but
there are 3,187 trackers on disk against 36,184 distinct sessions in the log — ~9% coverage,
because trackers are pruned and the log is not. Any analysis built on that join silently
describes a biased 9% of history.

### Why not per-plugin payloads

ONL-9 proposes adding `project_key` to four `librarian.*` payloads. That fix cannot reach the
hosted side at all, for the reason above, and it would have to be repeated for the other 15
namespaces. One envelope field closes ONL-9 and every sibling instance at once.

## What this spec decides

Four questions, each settled against a measurement rather than a preference.

### 1. The envelope carries an opaque key; names travel separately

Two optional fields on `event.v1.json`, joining the existing optional `adapter_id`,
`cost_usd`, and `token_count`:

| field | type | meaning |
|---|---|---|
| `project` | string, `^[0-9a-f]{12}$` | the unsalted project key, **byte-identical** to the on-disk directory name under `$ONLOOKER_DIR/<plugin>/<key>/` |
| `project_basis` | enum `remote` \| `root` | which derivation produced the key |

`additionalProperties: false` stays. Envelope `schema_version` stays `"1.0"`: adding optional
fields is backward compatible, and bumping it would make existing consumers reject new events.

A key alone is not a readable view — a dashboard row labeled `ee2cfbe428c7` is not an answer to
"which repo burns the most". The key → display-name mapping is uploaded by a **separate,
explicit, opt-in endpoint**, mirroring the existing `apps/api/src/routes/machine-inventory.ts`.
Repo names never ride the envelope.

**A correction to ONL-129's safety argument.** The bead claims the key is safe "because it is a
hash, not a path, so it carries no directory names or repo names off the machine". That does not
hold for a public repo: `remote:https://github.com/owner/name` is an *enumerable* input, so a
table over public repo URLs recovers any 48-bit key by brute force. The key is a pseudonym, not
a secret. Private repo URLs are not enumerable, so those stay opaque. This changes nothing about
the design — names reach the hosted side only by opt-in upload either way — but the claim should
not be repeated as written.

**Salting is not available.** The key is already the on-disk directory name for librarian,
lineage, curator, and historian. A salted envelope key would not match those directories, which
would break exactly the join ONL-9 exists to enable.

### 2. The basis is on the wire, because the root fallback is not rare

`onlooker_project_key` prefers `SHA256(remote:<origin-url>)`, which is portable across machines,
and falls back to `SHA256(root:<repo-root>)`, which is **machine-local**: the same remote-less
repo on a laptop and a desktop produces two different keys. Measured:

| | with origin | without origin |
|---|---|---|
| git repos under `~/src` | 26 | **6 (19%)** |

| plugin | on-disk keys | remote-derived | root-derived | unexplained |
|---|---|---|---|---|
| librarian | 21 | 14 | **4** | 3 |
| lineage | 17 | 12 | **2** | 3 |
| curator | 20 | 13 | **4** | 3 |
| historian | 16 | 11 | **3** | 2 |

`unexplained` counts on-disk keys matching neither derivation — repos since deleted, or
repos outside `~/src`. Roughly one in five tracked projects derives a machine-local key. Without a discriminator the
hosted view would split one repo into two rows across machines, with nothing on the wire
revealing it. `project_basis` lets a consumer aggregate confidently on `remote` and scope or
flag `root`.

Two alternatives were rejected. *Omitting* `project` for root-derived keys keeps the hosted view
honest but leaves ONL-9 unfixed for those projects — librarian has four such artifact
directories today. *Namespacing the value* (`root:7f3a91b2c4d8`) is self-describing but stops
matching the bare 12-hex directory names, so every local join needs a strip step.

**Accepted ambiguity, stated rather than hidden:** absence of `project` means either "not a git
repo" or "pre-2.28 emitter". No sentinel is introduced, because both cases mean "not
attributable" and every consumer handles them identically. The second case ages out.

### 3. One derivation, vendored and guarded

There are 13 `*-project-key.sh` files. Normalizing each plugin's own prefix and stripping
comments leaves **seven distinct implementations**:

| logic hash | lines | plugins |
|---|---|---|
| `80e2e3e96f` | 52 | **onlooker (canonical)**, assayer, bursar, curator, historian, librarian |
| `525401fe67` | 60 | archivist, tribunal |
| `620b1e356c` | 67 | inspector |
| `94a95c57ce` | 62 | lineage |
| `dca6eb4ce3` | 58 | counsel |
| `1e2caaab1a` | 66 | scribe |
| `e587e9940c` | 37 | cartographer |

`project-key.sh` is in neither `SHARED_LIBS` nor `ON_DEMAND_LIBS`, so nothing syncs these copies
and no test checks them for drift.

Measured against three directories, the divergence is narrower than the file count suggests —
and real:

| target | result |
|---|---|
| repo with an origin remote | all 13 agree: `ee2cfbe428c7` |
| repo with no origin remote | all 13 agree: `bc046590dad9` |
| not a git repo at all | 11 return empty; **cartographer and inspector return `715b9b271e0a`** |

Two implementations invent a key for a directory that is not a repo. Under this design they
would emit a `project` with basis `root` for `$HOME` or a scratch directory, seeding phantom
projects into the per-repo view, and they violate the contract in §2 that absence means "not a
git repo".

**Decision:** register `onlooker-project-key.sh` in **`ON_DEMAND_LIBS`**, promote
`scripts/lib/onlooker-project-key.sh` to canonical, delete the 12 per-plugin copies, and migrate
the call sites. This deletes the cartographer/inspector bug rather than patching it, since the
canonical already returns empty for a non-repo. No rename is needed: `sync-shared-libs.sh` derives
the canonical path from the bare entry name, so an entry of `onlooker-project-key.sh` resolves to
the file that already exists.

**On-demand, not shared** — corrected during planning, against this repo's own stated policy.
`sync-shared-libs.sh`'s header reserves `SHARED_LIBS` for libs vendored into *every* plugin
"because every hook uses them", and puts the rest in `ON_DEMAND_LIBS` because "a copy nobody
sources is noise that still has to be kept in sync". Twelve of sixteen plugins derive a project
key; compass, echo, governor, and warden never do. The requirement this design actually needs —
one implementation, guarded against drift — holds on either list: `shared-lib-vendoring.bats`
byte-compares every vendored on-demand copy, and its catch-all test, "every plugin vendors every
lib it sources from its own tree", covers this lib whichever list it is on, because all 12 source
it as `"${PLUGIN_ROOT}/scripts/lib/..."`. `SHARED_LIBS` would only add a never-sourced file to four
plugins. The cost of the on-demand list is that the first copy into each plugin is manual — the
sync script refreshes on-demand libs but never creates them.

**Three helpers have to move first.** The per-plugin files are not pure duplicates. Deleting them
blind would drop `worktree_root` (archivist, lineage, scribe, tribunal), `project_dir` (counsel,
scribe), and `canonical_path` (inspector). `worktree_root` becomes canonical as
`onlooker_worktree_root` — it is the documented counterpart to `onlooker_project_repo_root`, which
resolves a worktree to its parent for identity while this resolves the tree the session is in.
The other two embed a plugin name or are a plain path helper, so they move to plugin-local libs.

Cost, measured across all six renamed identifiers: **231 lines in 12 plugins and the test
suite**, plus nine per-plugin `*-project-key.bats` files that each test a copy. Twelve plugins
change, so twelve version bumps land in one release.

### 4. Per-project counts, because 17% of sessions span repos

`session_summaries` holds one row per `(machine_id, session_id)`. A single `project` column would
attribute all of a mixed session's events to one repo. Measured against lineage's ledger, which
already records a project key per session:

| | |
|---|---|
| lineage records | 9,342 |
| distinct sessions | 115 |
| sessions touching more than one project | **20 (17.4%)** |

One session touched three projects. So the summary carries a breakdown, mirroring how
`counts_by_prefix` already stores JSON in a D1 TEXT column:

```ts
counts_by_project: Record<string, { basis: "remote" | "root"; event_count: number }>
```

A scalar `project` — first-seen or modal — was rejected: it is silently wrong for a sixth of
sessions in exactly the "which repo burns the most" number the feature exists to produce, which
is the same class of defect as the root/remote split decided against in §2. One row per
`(session, project)` was rejected because it changes an existing table's primary key and leaves
session-level fields like `prompts` and `compactions` with no non-arbitrary way to split.

## Code shape

### schema 2.28.0

- `schemas/event.v1.json`: add optional `project` and `project_basis`; add
  `librarian.lesson.promoted` to the `event_type` enum.
- `schemas/payload/plugins-memory.json`: add the `librarian.lesson.promoted` payload —
  `lesson_id`, `outcome: approved | declined`, `duration_ms` (ONL-7).
- Regenerate `src/types.ts` and `src/event-types.ts`.

The schema registers 132 event types today, nine of them `librarian.*`, and none means "a lesson
was written" — re-verified against the installed 2.27.0, correcting ONL-7's note, which was
written against 2.18.0 and a count of 126.

### ecosystem

1. **Consolidate** (prerequisite): `ON_DEMAND_LIBS` gains `onlooker-project-key.sh`;
   `sync-shared-libs.sh` keeps the copies identical; the canonical gains `onlooker_worktree_root`;
   the three plugin-specific helpers move to plugin-local libs; 12 per-plugin libs and their bats
   files are removed; 231 lines move to the `onlooker_*` names. Planned in
   `docs/superpowers/plans/2026-10-10-project-key-consolidation.md`. **This unit has no schema
   dependency and can land before 2.28.0 publishes.**
2. **Resolve once per hook:** new `onlooker_project_resolve` sets and exports
   `ONLOOKER_PROJECT_KEY` and `ONLOOKER_PROJECT_BASIS` in a single pass. `onlooker_project_key`
   becomes a thin wrapper over it, but that wrapper does not reach existing call sites: every
   production caller invokes it as `PROJECT_KEY=$(onlooker_project_key "$CWD")`, and command
   substitution runs the call in a subshell, so the exports die there. Each emit site will call
   `onlooker_project_resolve` explicitly to populate the two variables. Latency is ~free — hooks
   already derive the key, so the basis folds into the same git pass.
3. **Emit:** `scripts/lib/onlooker-event.mjs` reads those two env vars in its envelope builder
   and omits both fields when either is empty.
4. **librarian:** emit `librarian.lesson.promoted` from `librarian_lesson_promote`
   (`librarian-lesson-promote.sh:44`), which has two terminal branches that both write into
   `lessons/` — approved to `approved/<lesson_id>.json`, declined to a row in `declined.jsonl`
   (ONL-7). The function emits nothing at all today.
5. **Triage** the new event type into `test/bus-coverage.json` per CLAUDE.md step 6.

The emitter reads env vars rather than taking per-call-site arguments or deriving the key in
JavaScript. No emit call site changes, and more importantly **the derivation is never
reimplemented in JS** — a JavaScript copy that drifted from the bash one would silently stop
matching the on-disk directory names, which is the entire point of the field.

### onlooker

- `apps/cli/src/sessions.ts`: add `project?` and `project_basis?` to `EventEnvelope`; accumulate
  `counts_by_project`.
- `packages/db`: new `counts_by_project` TEXT column on `session_summaries`, migration,
  `expected-schema.ts`, and schema tests.
- `apps/api`: accept the field on the sessions ingest route.

The safety story is unchanged: these are envelope fields and opaque hashes — never payload, never
names.

## Release train

```
schema 2.28.0  ──▶  ecosystem (pin bump, consolidate, emit)  ──▶  onlooker (summarizer, column)
```

The order is forced, not preferred. `additionalProperties: false` plus the bus-coverage gates in
`scripts/lint/check-bus-coverage.mjs` reject both the new envelope field and the new event type
until the schema release is published. Gate A rejects an unregistered emission; Gate B fails on
"manifest names a type the schema does not register".

The local schema clone can lag the published release — it did when this spec was written — so pull
it before editing, or the regenerated types will be built on a stale enum.

## Testing

- **Derivation:** all three cases — remote, root, non-repo — asserting the `715b9b271e0a`
  regression is gone. The nine per-plugin bats files collapse into one canonical suite; vendoring
  drift is covered automatically by `shared-lib-vendoring.bats`.
- **Emitter:** both fields present when the env vars are set; **both omitted** when either is
  empty; the emitted key equals the on-disk directory name for the same cwd.
- **librarian:** the promote site emits `librarian.lesson.promoted` on both the approved and
  declined branches, and emits nothing when the lesson id does not resolve.
- **Summarizer:** a two-project session produces two `counts_by_project` entries with the right
  per-project counts; a no-project session produces an empty map, not a null.

Run with `npm run test:bats`, never bare `bats` — bare `bats` skips schema validation, so the
negative schema assertions here would pass locally and fail in CI.

## Out of scope

Three follow-ups, each with independent surface, each getting its own spec:

1. **The key → name inventory endpoint.** Has real product surface: opt-in UX, per-repo consent,
   what happens to an unnamed key.
2. **The web per-repo view.** Worth designing against accumulated data, not an empty column.
3. **Doctor's librarian write-axis.** ONL-7's consumer half, in onlooker: `STREAMS` declares
   neither `writeHooks` nor `writeEvents` for librarian, so `computeVerdict`'s write axis never
   opens. The event this spec adds is the prerequisite.

No backfill. The ~218,738 existing events keep no project dimension; the `session-trackers` join
that could approximate one covers a biased 9% of history, which is why it is not used.

## Already done

ONL-10 (`ecosystem-449.39`) was batched into this release on the strength of its bead, then found
already implemented and shipped. Verified two ways against the working tree:

- `plugins/librarian/scripts/hooks/librarian-session-end.sh:143-158` emits
  `outcome: "skipped"` with `skip_reason: "no_new_artifacts"` on the no-new-artifacts path, and
  carries a comment explaining the distinction in the past tense.
- The installed schema 2.27.0 already registers `no_new_artifacts` in the memory `skip_reason`
  enum: `["archivist_not_present", "memory_path_unresolved", "disabled", "no_new_artifacts"]`.

So `empty` already means exactly one thing. The bead and the Linear issue are stale and should be
closed rather than worked.

This is the second stale fact found in the same batch — ONL-7's note was written against schema
2.18.0 and a count of 126 types, against 2.27.0 and 132 today. Neither bead was wrong when
written. Both argue for re-verifying a bead's load-bearing claims against the tree before
planning from it, which is why every `file:line` in this spec was checked rather than inherited.

## Risks

- **Twelve plugin version bumps in one release.** The consolidation is mechanical but wide. A
  mis-vendored copy fails `shared-lib-vendoring.bats` and `config-lib-self-locating.bats`, which
  is the intended safety net, but the diff is large enough to warrant reviewing the sync output
  rather than the 12 copies individually.
- **A sourcing mistake is silent.** Per CLAUDE.md, a lib resolved from a caller-supplied
  `$PLUGIN_ROOT` or a repo-root-climbing path leaves every accessor undefined while the script
  still exits 0. The vendored copy must resolve from its own `${BASH_SOURCE[0]}`.
- **The field is only as good as the basis.** If a future plugin derives a key by any path other
  than the canonical lib, the envelope and the on-disk directories diverge again, and the failure
  is invisible — a per-repo view that quietly double-counts. The vendoring guards are what keep
  this closed.

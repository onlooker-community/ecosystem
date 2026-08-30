# Lineage sees file changes, not tool calls — design

**Date:** 2026-08-30
**Tracking:** `ecosystem-449.13`
**Status:** Design approved, not implemented
**Depends on:** a `@onlooker-community/schema` release (see §5)

## 1. Problem

Lineage registers `PostToolUse` on `Write`, `Edit`, and `MultiEdit`. That matcher observes a
**tool call**, not a change to the filesystem. An agent that edits through the shell — a
heredoc, `sed -i`, a short Python script — moves the same bytes past an unwatched path.

The result is not a missing log line. `/lineage <file>:<line>` answers "no record" for a line
that was demonstrably written, and the ledger cannot distinguish *not recorded* from *not
changed*. A provenance tool that is silently partial is worse than one that is obviously
absent, because nothing signals the gap.

Same failure family as `ecosystem-449.10` and `ecosystem-449.12`: the hook exits 0, nothing
surfaces, and the only symptom is an absence nobody notices.

### Evidence

Session `26a26e04` (2026-08-30, ecosystem 0.45.3 / lineage 0.3.1), while doing unrelated work
with wave 1 live and auto mode active. Lineage recorded 9 changes, every one from a tool call.

It recorded **zero** for `docs/superpowers/plans/2026-08-30-onlooker-store-retention.md`, which
was modified twice via `python3` heredocs, landed in commit `5d5c0d3` as 21 insertions and 21
deletions, and shipped in #223.

That file is the worst one to lose: it is the execution record of the whole change. The gap was
found by accident during real work, not by a constructed test, which is the point — nothing
about the session looked wrong.

The downstream workaround (`onlooker-community/onlooker#99`, requiring tracked-file edits to go
through the tools) shapes the workload to fit the instrument. A plugin whose coverage depends on
every consumer adopting a convention has a matcher problem, not a documentation problem.

## 2. Goal and non-goals

**Goal.** Lineage records a change when a tracked file changes, regardless of which tool changed
it, with content good enough for its existing content-anchored lookup.

**Non-goals.**

- **Parsing shell commands to find file writes.** Covering `sed -i`, `tee`, heredoc redirection,
  `python -c`, and shell rewrites is an open-ended parsing problem, and a wrong parse writes a
  false ledger entry — worse than a missing one. Git is asked what changed instead.
- **Inspector.** The bead names it too, but its remedy (run lint on shell-touched files) collides
  with `ecosystem-449.14`'s unresolved finding that inspector's dispatch overhead is already 4–5x
  the check it wraps. Split to its own bead.
- **Byte-exact per-command attribution.** See `content_scope` in §4.

## 3. Detection

A new `PostToolUse` matcher on `Bash` in `plugins/lineage/hooks/hooks.json`, routed to the
existing hook script.

The hook runs one `git status --porcelain=v1 -z` and compares against a stored baseline:

1. Hash the `git status` output. If it differs from the baseline hash, the dirty set changed.
2. For each path in the baseline's dirty set, compare its stored content hash to the current one.

Both checks are needed. A file that was already dirty and is edited again produces byte-identical
`git status` output — an unchanged modified-status line for the same path — so a status hash alone
misses the second edit, the same class of silent miss this bead is about.

If neither check fires, the hook exits. That is the common path: most Bash calls write nothing.

**Why a rolling baseline rather than a `PreToolUse` snapshot.** One hook instead of two on the
hottest event, and it self-corrects. It also catches changes from any source lineage does not hook
at all, not just Bash. The cost is that the delta is "since the last check" rather than strictly
"this command" — acceptable, because every other writer (`Edit`/`Write`/`MultiEdit`) records its
own change and advances the baseline.

## 4. Storage and record shape

### Baseline location

`$ONLOOKER_DIR/lineage-baselines/<project-key>/<session-id>.json`, holding a SHA-256 of the
`git status` output and a `path → SHA-256` map for the dirty set. Both reuse the same digest
helper the ledger already uses for `content_sha256`.

**It must not live under `$ONLOOKER_DIR/lineage/`.** That path is on the durable never-touch list
in `scripts/onlooker-store-prune.mjs`, and a per-session baseline is scratch by definition. Putting
it there recreates `ecosystem-449.2` inside the store that bead just bounded.

`lineage-baselines` is therefore added to the prune script's `STORES` allowlist under the
`scratch` policy (48h), alongside `session-trackers`.

### Two new record fields

**`provenance_kind`** — `authored` or `tool_generated`, classified from `tool_input.command`.

Confident mechanical matches tag as `tool_generated`: `git checkout|switch|merge|rebase|pull|stash`,
`npm|pnpm|yarn install|ci`, formatters (`biome`, `prettier`, `black`), release tooling.
**Everything else defaults to `authored`.**

The default matters. If unclassified changes defaulted to `tool_generated` and `/lineage` filtered
them out, a tool nobody thought of would vanish silently — reintroducing this bug one layer up.
Defaulting to `authored` means an unrecognized writer shows up as noise, which is visible and
fixable. Fail loud.

**`content_scope`** — `delta` or `cumulative`.

Added content comes from `git diff HEAD -- <file>`. When the file was clean at baseline, that diff
*is* exactly this change (`delta`). When it was already dirty, the diff also includes earlier
uncommitted work (`cumulative`).

This avoids storing prior file content or writing git blobs, at the cost of over-inclusive content
in the `cumulative` case. Lineage's lookup tolerates over-inclusion — it finds the most recent
change whose added content contains the queried line, so the failure mode is attributing a line to
a slightly later change, never returning nothing. Tagging it keeps the imprecision auditable.

**`cumulative` will be the common case.** Agents usually work with a dirty tree. This is a real
fidelity ceiling and lineage's README must say so.

### Reused as-is

Project key resolution, `ignore_globs`, `max_snippet_chars`, secret redaction, the ULID generator,
and the ledger append path all work unchanged.

## 5. Required schema change (blocking, separate repo)

`lineage.change.recorded` in `@onlooker-community/schema` (`schemas/payload/plugins-ops.json`)
is strict, and blocks this three ways:

```json
{
  "additionalProperties": false,
  "tool":      { "enum": ["Edit", "Write", "MultiEdit"] },
  "operation": { "enum": ["create", "overwrite", "edit", "multi_edit"] }
}
```

The change needed:

- add `"Bash"` to the `tool` enum
- add `"shell_edit"` to the `operation` enum
- add `provenance_kind` (enum: `authored`, `tool_generated`)
- add `content_scope` (enum: `delta`, `cumulative`)

This ships and publishes **first**; the ecosystem side then bumps the dependency. The local schema
checkout is on an unmerged branch at 2.14.0 while ecosystem consumes the published 2.15.0, so the
schema repo needs syncing to main before the change is authored.

No new event *type* is introduced, so `test/bus-coverage.json` needs no new entry.

**Why this cannot be skipped.** The runtime emitter fails open ([ADR-005](../../adr/005-runtime-emitter-fails-open.md)):
it validates only when the schema package resolves. Emitting `tool: "Bash"` without the schema
change would fail tests in CI and dev — and silently emit an invalid event from every installed
plugin, which ships no `node_modules`.

## 6. Risks

**`git status` on the hottest hook.** Roughly 10–30ms in this repo, but unbounded in a large
working tree. Bash outruns `Edit` by about 30:1, so this is a per-session cost multiplier, not a
per-edit one. It needs measuring against the ~35ms `tool-sequence-tracker` baseline before it
ships. This is precisely the "cheap per-edit loop" claim `449.14` just caught inspector failing —
the same scrutiny applies here.

**Lockfile noise.** `ignore_globs` currently has `**/*.lock`, which does not match
`package-lock.json` or `pnpm-lock.yaml`. Every `npm ci` will otherwise produce a `tool_generated`
record for a multi-thousand-line diff. The glob list needs extending as part of this work.

**Non-git projects and detached states.** No git, no baseline, no records — the hook must fail
soft and exit 0, matching current behavior for files outside the repo.

## 7. Testing

Per `.claude/skills/writing-tests`, bats against `$ONLOOKER_DIR` in an isolated temp home.

- shell edit to a tracked file produces a ledger record
- a Bash call that writes nothing produces no record and no baseline churn
- a file already dirty at baseline, edited again, is still detected (the identical-`git status` case)
- `content_scope` is `delta` for a clean-at-baseline file, `cumulative` for a dirty one
- `provenance_kind` is `tool_generated` for `git switch` and `npm ci`, `authored` for a heredoc
- an unrecognized command defaults to `authored`
- `ignore_globs` still suppresses lockfiles and `node_modules`
- no git repo: exits 0, records nothing
- baseline lands under `lineage-baselines/`, never under `lineage/`

Every non-final `[[ ]]` needs `|| return 1`. Break one assertion on purpose to confirm the tests
gate before trusting them.

## 8. Out of scope

- Inspector's equivalent gap — its own bead, after `449.14`.
- Backfilling provenance for changes already missed. Unrecoverable; the ledger starts being
  complete from the fix forward.
- `ecosystem-449.11`'s latency re-baseline, which should run **after** this lands. Baselining
  while most edits bypass the recorders measures roughly 176ms instead of the ~1106ms an
  Edit-tool change actually costs — understating wave 1 by about 6x.

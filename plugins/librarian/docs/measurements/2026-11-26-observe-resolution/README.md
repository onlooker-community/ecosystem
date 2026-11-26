# How often Observe versions a stored lesson's stack — 2026-11-26

Rollout step 2 of ONL-313 gives librarian an Observe lib that reads the
versions a lesson's stack entries ran on. This measures it against the lesson
candidates already stored, before anything calls it. It reads the real store and
repos, writes nothing to either, and makes no model call.

## What was run

| | |
| --- | --- |
| date | 2026-11-26 |
| ecosystem checkout | `f3c31024` on `meagan/onl-313-observe-versions` (includes the resolver fixes described below) |
| store | `~/.onlooker/librarian`, 215 candidates across 9 projects |
| probe | read **this machine**, as of the run, not the session's |
| script | `run.mjs`; `concepts.txt` lists the stack entries that name a concept, not a versioned thing |

`node run.mjs` reproduces the committed numbers. For a comparison run, pass a
different concepts file as the second argument and set `RESULTS_OUT=none`.

Two review rounds changed the resolver after a first run scored 163 of 215
(76%). Reading that run turned up two real gaps, fixed in `0085f7f5` with tests
first (172 of 215, 80%): `pnpm` is pinned in `package.json`'s `packageManager`
field, and `biome` or `auth-core` name a package the manifests write as
`@scope/name`. The second round, `f3c31024`, is below. The numbers in the
tables are after both.

## Result against the 39% baseline

The baseline was 83 of 215 (39%), from a scratch run that read only manifests
at HEAD. The headline is `fully_resolved + concepts_only` over all candidates,
counted the same way. The candidate total is the same, 215.

| | fully_resolved | concepts_only | partly | none | headline |
| --- | ---: | ---: | ---: | ---: | ---: |
| with `concepts.txt` (25 entries) | 146 | 19 | 17 | 33 | **165 of 215 (77%)** |
| empty concepts file | 136 | 0 | 32 | 47 | **136 of 215 (63%)** |

The topics split is worth 29 candidates (13 points) by itself: those stacks are
concepts, and once rollout step 3 moves them to `topics` they stop counting
against resolution. The other 63% is Observe, with no help from the split. Both
clear the spec's 60 to 70% estimate; with the split the result is above it.

Stack entries that were not strings: 0.

## Observed entries, by source and basis

From the run with `concepts.txt`, counting entries rather than candidates:

| source | basis | entries |
| --- | --- | ---: |
| component | session_commit | 74 |
| lockfile | session_commit | 61 |
| probe | machine | 58 |
| mise | session_commit | 10 |
| manifest | session_commit | 3 |

Components and lockfiles carry most of it. Manifests, which is all the
baseline read, account for only 3 entries here, because a lockfile's exact
version outranks a manifest's range.

## What is still unresolved

50 candidates, with `concepts.txt` applied. Entries that name a hosted service:

- Cloudflare Workers (7), Sentry (7), GitHub Actions (4), Cloudflare (3), D1 (2),
  cloudflare-workers, GitHub, GitHub Apps. This is open question 2 and is left
  alone.

Workflow pins are deliberately left unresolved too. A `uses:` pin is the
action's version, not the tool's: `release-please` was recorded as `4` and
`mise` as a commit SHA. Observe no longer reads `.github/workflows` at all,
pending open question 2 (`workflow` stays in the contract's enum). That costs 7
candidates, all with `release-please` in the stack, which is why the headline
fell from 172 to 165. The `@types/*` scope is excluded from the unscoped-name
alias, because `@types/node` is not node's version, and the alias runs last,
after the probe, so a better source for the same name always wins.

Concepts added during Step 4, because they name nothing with a version: email,
monitoring, documentation, deployment, API validation, API contracts,
api-testing, mock validation.

Known gaps, deliberately not fixed:

- **Turbo** (2). It could be Hotwire Turbo or Turborepo, and the lockfile has
  `turbo-rails`. Guessing the alias is what Observe exists not to do.
- **beads** and **bd** (3). The probe allowlist is a spec constraint, and the
  binary is not on it. The same applies to zsh, fish and python (1 each).

Anything else, left unresolved because they might be components or are names of
this repo's own scripts: cli (2), invite-system, onlooker-api, machine-tokens,
project-labels, pairwise-stats, hook-rollup, Claude, programming. Two more
entries were seen only in candidates from a repo that is not mine, and are not
named here.

## Caveats

- A probe reads today's machine, not the session's. Every probed entry says
  `basis: machine` for that reason.
- Component and manifest reads use `--before=<observed_at>` on the current
  HEAD's history, so a rebased branch can change the answer.
- A manifest range is recorded as written, for example `^2.4.11`. The
  observation says what the project declared, which is not always what ran.
- `results.jsonl` holds 214 rows, not 215, and `run.mjs` filters them by the
  manifest's remote, so rerunning it reproduces the file exactly. One candidate comes from a repo
  outside `github.com/meaganewaller/` and `github.com/onlooker-community/`, and
  this repo is public, so its row is dropped. The counts above cover all 215.

## What rollout step 3 should take from it

- Move the 25 concept entries to `topics`. They are about 13 points of the
  headline on their own.
- Resolution is above the 60% bar, so the remaining gap is the three groups
  above: hosted services (the most frequent entries), the probe
  allowlist, and a handful of ambiguous names.
- Hosted services are the largest group. Whether they get a version at all is
  open question 2, and nothing here answers it.

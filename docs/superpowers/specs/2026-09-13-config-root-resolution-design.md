# Config root resolution

Design for `ecosystem-449.37` acceptance 5 — which root each plugin's
`*_config_load` receives, and the bug class that made the question unanswerable.

## Problem

`config_load_plugin` takes a root and builds two paths from it:

```bash
repo_file="${repo_root}/.claude/settings.json"
repo_local_file="${repo_root}/.claude/settings.local.json"
```

Any string is accepted. A wrong one produces no error, no event, and no test
failure — the layers simply do not exist, `jq` fills them with `//`, and the
plugin runs on shipped defaults. Three bugs have now come out of that hole:

- `ecosystem-ber` — installed plugins could not resolve `config-loader.sh`, so
  every accessor was undefined and all config fell back to defaults.
- `ecosystem-68z` — the loader read `$HOME/.claude/settings.json`, so user-level
  config was unreachable on a custom `CLAUDE_CONFIG_DIR`.
- This one, below, in two flavors.

All three share a signature: **config silently resolves to shipped defaults,
exit 0**.

### Category A — parent-root readers, wrong in a worktree

Fourteen call sites across thirteen hooks pass `$REPO_ROOT`, which comes from
`*_project_repo_root` and deliberately resolves a linked worktree to its *parent*
checkout so both share a project key. That is correct for identity and wrong for
reading files. In a worktree session these ten plugins read the parent checkout's
`.claude/settings.json` — a different branch's config:

archivist, assayer, cartographer, counsel, curator, echo, historian, librarian,
lineage, tribunal.

**Inspector is not in this list**, though it also passes `$REPO_ROOT`.
`inspector_project_repo_root` resolves through `--show-toplevel` rather than
`--git-common-dir`, so its root is already the worktree. This is the asymmetry
that surfaced `ecosystem-449.33` in the first place: inspector kept working in
the `onlooker-ac5` worktree while lineage went silent. Inspector's two call sites
still change under this design, but only so layer 5 moves to the parent — its
layer 4 is correct today.

This is `ecosystem-449.37` tier 3. Tiers 1 and 2 — the same root reused for git
reads and artifact paths — are already fixed on `main` across lineage (#263),
tribunal (#266), echo, scribe and archivist. `lineage-post-tool-use.sh:150`
records the deferral explicitly:

> The two `lineage_config_load` calls below are the deliberate exception: they
> still take `REPO_ROOT`, so a worktree reads its parent checkout's config. That
> is config resolution rather than a path operation, it is the same question
> every plugin here answers the same way, and `ecosystem-449.37` settles it
> across all of them.

### Category B — raw-cwd readers, wrong from a subdirectory

Sixteen call sites pass `$CWD` — the session's working directory, straight off
the hook payload, with no resolution:

compass, governor, scribe, warden, bursar.

The loader does not walk upward. When the session's cwd is a subdirectory of the
repo, `${cwd}/.claude/settings.json` does not exist and **both** repo layers
vanish. Verified against the real loader:

```text
repo root passed in -> FROM_REPO_SETTINGS
subdir   passed in -> SHIPPED_DEFAULT
```

This is not recorded in any bead, and it is the more severe of the two: category
A reads the wrong branch's config, category B reads no project config at all.

### Both are observed, not theoretical

Distinct `cwd` values recorded in `~/.onlooker` state:

| Shape | Recorded cwds |
|---|---|
| Worktree (category A) | `ecosystem-449.55`, `ecosystem-449.35`, `ecosystem-449.36`, `ecosystem-449.34-sink`, `ecosystem-449.48`, `onlooker-ac5`, `schema-449.55` |
| Subdirectory (category B) | `onlooker/apps/web` (4 sessions), `onlooker/apps/web/src` (3), `onlooker/packages/brand` (1) |

In those eight subdirectory sessions, compass, governor, scribe, warden and
bursar ran on shipped defaults with both `.claude/settings.json` layers absent.

There is a live instance in this checkout right now: `main` and the
`ecosystem-449.55` worktree disagree about whether tribunal is enabled, because
the worktree holds its branch's committed `settings.json` and `main` holds the
re-enable flip.

## Goals

1. Answer acceptance 5: every `*_config_load` root is a deliberate decision.
2. Fix category B, and record it.
3. Make a fourth instance of the bug class structurally impossible rather than
   merely discouraged.

## Non-goals

- **Moving project keys.** `*_project_repo_root` and every `*_worktree_root` are
  untouched. Acceptance 7 requires a worktree and its parent to keep resolving to
  the same key, so no plugin's storage partitioning changes.
- **The `~/.claude` layers.** Layers 2 and 3 were settled by `ecosystem-68z`.
- **Tiers 1 and 2.** Already on `main`.
- **A config-validation lint.** ADR-004 notes that unknown `settings.json` keys
  silently do nothing. Still true, still out of scope.

## The rule

Three roots, three purposes, never interchangeable:

| Root | Derived from | Purpose |
|---|---|---|
| **project-key root** | `--git-common-dir` → parent | Identity. Which store or ledger this session writes to. Worktrees share it. |
| **worktree root** | `--show-toplevel` | Location. Containment, `git diff`, file reads, artifact output paths. |
| **session cwd** | hook payload `.cwd` | Input only. Resolves the other two. Never a root itself. |

The bug in every tier of `449.37` is one name bound to two of these values. The
fix, applied five times already, is to keep them distinct and make each site say
which it wants.

### Config splits across the first two

The two repo-scoped precedence layers have different natures, so no single root
is right for both:

- **Layer 4** `.claude/settings.json` is **committed**, therefore *branch-scoped*.
  The dogfooding epic stages plugin rollout through this exact file, so a worktree
  testing a config change must see its own copy.
- **Layer 5** `.claude/settings.local.json` is **gitignored** (globally, via
  `~/.config/git/ignore:84`), therefore *machine-scoped*. `git worktree add` never
  copies it, so it exists only in the main checkout.

Resolving both against the worktree would silently drop layer 5 in every worktree
session — repeating the original mistake at smaller scale. Resolving both against
the parent would make a branch unable to configure itself, which is the thing the
epic uses layer 4 to do.

Final precedence, latest wins:

```text
1. <plugin>/config.json                    shipped defaults
2. <claude_dir>/settings.json              user
3. <claude_dir>/settings.local.json        user local
4. <worktree>/.claude/settings.json        project, branch-scoped
5. <parent>/.claude/settings.local.json    project local, machine-scoped
```

## Loader change

`config_load_plugin <plugin> <cwd> <out_var>`. **Arity is unchanged**; argument 2
is reinterpreted from "repo root" to "session cwd", and the loader derives both
roots itself:

```bash
git -C "$cwd" rev-parse --show-toplevel --git-common-dir
#  line 1 -> worktree_root
#  line 2 -> common dir; absolutized then /.. -> parent_root
```

One fork, both answers. Measured at ~4.8ms against ~9.7ms for two separate
`rev-parse` calls, which matters because hook cost is already a live concern
(`ecosystem-449.29`, `449.43`, `ff7`, `6ce`).

Details that are load-bearing:

- **`--git-common-dir` returns a relative path in a normal checkout** (`.git`) and
  an absolute one in a worktree. It is absolutized with the `cd … && pwd -P`
  idiom the `*-project-key.sh` libs already use, not `realpath`, which is not
  portable across the macOS and Linux legs of CI.
- **Empty, non-git, or nonexistent cwd** → both roots empty → layers 4 and 5
  skipped. Defaults and user layers still apply. This preserves the loader's
  existing no-repo contract, where `""` meant "no repo".
- **Resolved roots are memoized per cwd** for the process, so a hook calling the
  loader twice (`inspector-post-write.sh:76,82`) pays one fork.

### Why this is backward compatible

A caller that still passes a repo root is passing a *valid cwd*, so it resolves
correctly. A caller passing the parent root from inside a worktree resolves
`worktree_root` to the parent and degrades to today's behavior rather than
breaking. There is no flag day across the sixteen vendored copies.

### Why the loader resolves rather than the call sites

The alternative — thread `worktree_root` and `parent_root` through as explicit
arguments — keeps the choice visible at each site but leaves thirty-three places
that can be wrong, which is how all three bugs happened. Moving resolution inside the
loader means no call site picks a root, so no call site can pick the wrong one.
It removes the class instead of fixing thirty-three instances of it.

## Call sites

Thirty-three total; seventeen change.

| Change | Sites | Where | Why |
|---|---|---|---|
| `$REPO_ROOT` → `$CWD` | 14 | 13 hooks across archivist, assayer, cartographer, counsel, curator, echo, historian, librarian, lineage, tribunal | Category A: layer 4 currently reads the parent |
| `$REPO_ROOT` → `$CWD` | 2 | `inspector-post-write.sh:76,82` | Layer 4 already correct; moves layer 5 to the parent |
| `$(librarian_project_repo_root "$CWD")` → `$CWD` | 1 | `librarian-session-end.sh:88` | Category A, written inline rather than via `$REPO_ROOT` |
| none | 16 | bursar, compass, governor, scribe, warden | Category B, fixed inside the loader |

The sixteen already passing `$CWD` need no edit: their defect is category B, and
the loader now resolves what they were passing raw.

Note that `$REPO_ROOT` remains live in several of these hooks for non-config
purposes — `librarian-session-end.sh:96` still hands it to
`librarian_storage_write_manifest`, which wants identity. Only the
`*_config_load` argument changes.

Documentation touched in the same change:

- `scripts/lib/config-loader.sh` — the usage block and the precedence list, which
  currently document argument 2 as a repo root.
- Each plugin's `<name>-config.sh` usage comment, via `sync-shared-libs.sh`.
- `lineage-post-tool-use.sh:150-154` — the deferral comment, now settled.
- `docs/adr/004-plugin-config-with-settings-overlay.md` — a consequence noting
  that layers 4 and 5 resolve against different roots, and why.

## Testing

New `test/bats/config-loader-roots.bats`, driven from a real `git worktree add`
rather than a simulated directory layout — per acceptance 6, and because the
relative-vs-absolute `--git-common-dir` behavior only appears in a real one:

1. **subdir cwd resolves layer 4** — the category B regression.
2. **worktree cwd reads the worktree's layer 4**, not the parent's, with the two
   trees holding different values so the assertion cannot pass by accident.
3. **worktree cwd reads the parent's layer 5.**
4. **non-git cwd** → shipped defaults, exit 0.
5. **empty cwd** → shipped defaults, exit 0.
6. **repo root passed as cwd still resolves** — the back-compat guarantee.

Test 2 follows the shape `echo-stop-gate-worktree.bats` established: dirty both
sides so the only variable is which tree was read. A test that distinguishes the
trees only by one being empty proves less than it appears to.

Drift across the sixteen vendored copies is already covered by
`shared-lib-vendoring.bats` and `config-lib-self-locating.bats`; this change adds
no new vendoring surface, only new content in an existing shared lib.

### Enforcement

One additional test, in the style of `config-lib-self-locating.bats` and
`hook-health.bats`: no hook may pass a `*_project_repo_root` result into
`*_config_load`. The loader change makes the *root* unpickable, but a call site
can still hand it the wrong *input*, and passing the parent root as cwd is the
exact mistake that reads as correct.

## Beads

- A new child of `ecosystem-449.37` for category B, recording the five plugins,
  the sixteen call sites, and the eight observed subdirectory sessions.
- Acceptance 5 answered on `ecosystem-449.37` with the rule above.

## Risks

- **Every plugin's effective config changes in a worktree session**, which is the
  point, but it means a worktree whose branch predates a `settings.json` change
  now runs the older config where it previously inherited the parent's newer one.
  That is correct and was the goal; it will still look like a regression the first
  time it is noticed.
- **Memoization is process-scoped state in a vendored lib.** Hooks are
  short-lived, one process per fire, so the cache cannot outlive a single hook
  invocation. If that ever stops being true the cache key must include cwd — it
  does — and nothing else about the process may vary.
- **`--show-toplevel --git-common-dir` ordering is depended upon.** Git emits
  them in argument order; the test suite asserts the parse rather than trusting it.
- **Linux and macOS disagree about git plumbing more than expected.** Two CI-only
  failures in the previous session were exactly this. The new bats file runs real
  `git worktree add` on both legs.

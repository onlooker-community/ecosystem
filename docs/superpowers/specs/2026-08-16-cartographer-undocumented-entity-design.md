# Cartographer `undocumented_entity` Phase — Design

**Status:** Approved, not started.
**Tracked by:** `ecosystem-3eu`.
**Single repository.** Everything lands under `plugins/cartographer/`.

---

## What this is

Cartographer's four analysis phases all start from the *text* of the instruction
files. `contradiction` and `dead_rule` compare rules against each other,
`scope_collision` compares project rules against global ones, and `stale_ref`
extracts path-like tokens out of the instruction files and tests them on the
filesystem (`cartographer-analyze.sh:99-125`).

Every phase walks doc → disk. Nothing walks disk → doc.

So something that exists on disk and is simply not mentioned is structurally
invisible: it produces no token to extract, no contradiction, no dead rule, and
no scope collision. This is why cartographer never flagged that `CLAUDE.md`'s
plugin map documented 12 of 17 plugins, omitting `librarian` — the plugin that
owns the entire upstream chain the lesson-promotion pipeline hangs off. Found
while fixing `ecosystem-yp8`.

This is a coverage gap, not a defect. An omission is a different class of drift
from a stale reference, and cartographer was only ever built to catch the
latter.

## Why an absence is not automatically a defect

The obvious framing — "enumerate everything on disk, flag whatever no
instruction file mentions" — produces noise, because most of a repository has no
business being named in `CLAUDE.md`.

`docs/adr/` is the clean counterexample. Five ADRs sit on disk; `CLAUDE.md` names
ADR-001, ADR-004, and ADR-005 and says nothing about 002 or 003. That is correct.
`CLAUDE.md` is not an ADR index — `docs/adr/` is its own index, and an ADR earns
a mention in the instruction files only when an agent needs to know about it.

Meanwhile `plugins/librarian/` being absent from the plugin map *was* a real
defect, and `skills/list-prompt-rules/` is one right now: it appears zero times
in both `CLAUDE.md` and `AGENTS.md`.

So the phase cannot ask "is this mentioned?" in the abstract. It has to be told
**where completeness is expected**. That is the job of the `globs` config: an
opt-in list naming the entity classes whose enumeration is supposed to be
complete. Anything not matched by a glob is never considered, which is what
keeps `docs/adr/` permanently out of scope without a special case.

## Detection

Pure bash. No model call.

```
for each glob in config.globs:
  for each match under repo_root:
    name = basename(match)
    if not mentioned(name) in DISCOVERED_FILES:
      → finding
```

Three details carry weight:

**Corpus is `DISCOVERED_FILES` only, never `GLOBAL_FILES`.** The user's global
`~/.claude/CLAUDE.md` has no business documenting one project's plugins. Counting
a global mention as coverage would let an unrelated personal note silence a real
project-level omission.

**`mentioned()` is a word-boundary match**, `grep -qE "\b<escaped>\b"`, not
`grep -F`. A substring test would let the word "counseling" satisfy an entity
named `counsel`. The name is regex-escaped before interpolation.

**Detection needs no LLM, and deliberately does not use one.** Presence or
absence of a name is a grep. A model call would only be useful for judging
whether an omission *matters*, which is a sharper question than the drift that
motivated this — `librarian` was absent entirely, and the crudest possible check
catches that. Adding a materiality judge now would spend a model call per audit
to solve a problem we have not yet observed. If the false-positive rate turns out
to warrant it, the `stale_ref` classify pre-pass is the shape to copy.

## Where it sits in the pipeline

A third analysis inside `run_synthesize`, alongside `stale_ref` and
`scope_collision` — **not** a sixth pipeline phase.

The phase list (`discover` / `extract` / `relate` / `synthesize` / `emit`) stays
as it is, so run records keep their current shape and the `phases_completed` and
`phases_failed` arrays in `runs/audit-<id>.json` do not gain a new member.
Consumers reading those records do not need to change.

New library: `plugins/cartographer/scripts/lib/cartographer-omission.sh`,
exporting:

```
cartographer_analyze_undocumented_entity <files_json> <repo_root> <globs_json> \
    <exclude_json> <max_findings>
```

It prints a JSON array of findings on stdout, matching the shape the other
analyzers return, so `run_synthesize` merges it into `raw_all` with no special
handling and the existing hash-enrichment loop covers it unchanged.

It is invoked under `$_TIMEOUT_CMD "$_phase_timeout"` like its siblings. The work
is fast, but a pathological glob over a huge tree should be killed on the same
terms as everything else rather than being trusted because it is "just bash".

## Finding shape

```json
{
  "type": "undocumented_entity",
  "severity": "warning",
  "file_a": "<absolute path to the entity>",
  "excerpt_a": "<entity name>",
  "file_b": null,
  "excerpt_b": null,
  "description": "<name> exists at <relative path> but is not mentioned in any instruction file.",
  "suggested_fix": "Document <name> in CLAUDE.md, or exclude its path from cartographer.undocumented_entity."
}
```

**`file_a` is the entity, not a document.** There is no single instruction file
at fault — the entity is missing from the whole corpus, so naming one file would
be arbitrary. Keying identity on the entity also makes
`cartographer_finding_hash` stable when someone reorganizes `CLAUDE.md`: a
finding must not re-fire as new because a heading moved. With `file_b` and
`excerpt_b` empty, the existing commutative hash degenerates to a stable
per-entity key, which is exactly the dedup behavior wanted — one finding per
undocumented entity, once, until it is resolved.

**Severity is always `warning`.** The existing definition reserves `error` for
rules whose violation would compromise safety or produce incorrect output. A
missing mention is neither.

## Configuration

Under the `.cartographer` namespace in `config.json`, overridable through the
standard five-layer settings overlay (ecosystem `docs/adr/004`):

```json
"undocumented_entity": {
  "enabled": true,
  "globs": ["plugins/*/", "skills/*/"],
  "exclude": [],
  "max_findings": 20
}
```

- **`globs`** — repo-root-relative. The defaults are Claude Code layout
  conventions rather than ecosystem-specific paths, and a glob that matches
  nothing yields no candidates, so this is silently inert in a repository
  without those directories. That is what makes shipping it enabled defensible:
  it is useful out of the box where the convention holds and invisible where it
  does not.
- **`exclude`** — substring filter over matched paths, mirroring the semantics
  of the existing top-level `exclude_paths`. That field replaces rather than
  merges when a settings layer overrides it (cartographer
  `docs/adr/004-exclude-paths-replace-semantics.md`); this field follows the
  same rule, and the README must say so, because replace-not-merge is the
  behavior users get wrong.
- **`max_findings`** — see below.
- **`enabled: false`** short-circuits to `[]` before any filesystem walk.

## Two edge cases that decide correctness

**Targeted post-write audits skip this phase entirely.** When
`CARTOGRAPHER_TARGET_FILE` is set, `run_discover` sets `DISCOVERED_FILES` to that
one file. Grepping a single file for every entity name in the repository would
report almost the entire enumeration as undocumented — a burst of false findings
that would then be dedup-sentineled and never re-evaluated, poisoning the
findings store permanently. The phase therefore returns `[]` when `TARGET_FILE`
is non-empty.

This follows established precedent rather than inventing one: `scope_collision`
already no-ops on targeted runs, because `run_discover` sets `GLOBAL_FILES` to
`[]` and the analyzer returns early on an empty corpus.

**First-run noise is capped at `max_findings`.** Enabling this against a
repository with a thin `CLAUDE.md` could otherwise produce dozens of findings in
one audit. The count of dropped candidates is written to `audit.log`; a silent
truncation would read as "this is everything" when it is not.

## Event emission is knowingly broken, and not fixed here

`cartographer.issue.found` does not validate against the published schema and
never has. `run-audit.sh` emits `finding_type` / `affected_files` /
`finding_hash`; `@onlooker-community/schema` 2.12.0 requires `issue_type` and
`file_path` with `additionalProperties: false`. `cartographer.audit.complete` is
off-contract too. Verified by piping both payloads through the real
`scripts/lib/onlooker-event.mjs emit` path — each exits 1.

Per ADR-005 the consequence differs by install mode. In a dev or CI checkout the
schema package resolves, validation runs, `cartographer_emit_event` returns 1,
and `emit_safe`'s `|| true` swallows it, so nothing reaches the bus. In an
installed marketplace plugin there is no `node_modules`, the emitter fails open,
and off-contract payloads are emitted. Findings still reach
`findings/<hash>.json` in both modes, which is why `/cartographer` looks healthy
and this has gone unnoticed.

**This is tracked separately as `ecosystem-q4d` (P1) and is out of scope here.**
Findings from this phase land on disk exactly like the other four, and its bus
event is broken in exactly the same way until `q4d` lands. Folding the fix in
would mix a bug fix with a feature and pull an upstream schema change into the
middle of a feature branch — the same reasoning that split `4d3` / `cs8` / `973`.

Worth recording: the published schema's `issue_type` enum already contains
`orphaned_plugin`, and `issue_categories` already contains `orphaned_plugins`.
The contract anticipated disk → doc detection; the implementation never built
it. Whoever resolves `q4d` should decide whether `undocumented_entity` maps onto
that existing name or whether the enum grows a new member.

## Testing

bats, following `test/helpers/setup.bash` and the repo's `writing-tests` skill —
isolated temp home, no writes to the real `~/.onlooker/`.

| Case | Expectation |
|------|-------------|
| Entity on disk, name absent from corpus | one finding, `type=undocumented_entity` |
| Entity on disk, name present in corpus | no finding |
| Entity `counsel`, corpus says "counseling" | one finding — word boundary holds |
| Path matches `exclude` | no finding |
| `enabled: false` | `[]`, no filesystem walk |
| Glob matching nothing | `[]` |
| `TARGET_FILE` set | `[]` |
| Candidates exceed `max_findings` | capped, drop count in `audit.log` |
| Same entity across two runs | identical `finding_hash` |

## Acceptance

Run a full audit against this repository. The phase reports exactly one finding
— `skills/list-prompt-rules` — and nothing else. All 16 plugins under `plugins/`
are currently documented in `CLAUDE.md`, and `docs/adr/` is never enumerated.

That one-finding result is the acceptance signal in both directions: it proves
the detection fires on a real gap, and it proves the enumeration is narrow
enough not to bury that gap in noise.

## Documentation to update

- `plugins/cartographer/README.md` — phase list and the new config block.
- `plugins/cartographer/skills/cartographer/SKILL.md` — the `--phase` value list
  at line 112, and the frontmatter `description`, which enumerates what
  cartographer audits for. The finding renderers at lines 65 and 135 read
  `.type` and `.description` generically and need no change.
- `CLAUDE.md` — the cartographer row in the plugin map describes the hook
  surface, not the phases, so it likely needs no change. Confirm at
  implementation time.

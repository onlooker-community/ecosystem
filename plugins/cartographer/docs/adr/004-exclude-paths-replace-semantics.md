# ADR-004: exclude_paths Uses Replace Semantics

**Status:** Accepted

## Context

The `exclude_paths` config key lists directory name substrings that `find` should skip. Users may want to customize this list — adding project-specific directories like `fixtures/` or `testdata/`. Two approaches:

1. **Replace semantics:** Overriding `exclude_paths` replaces the entire list. Users who want to extend must repeat the defaults plus their additions.
2. **Append semantics via `exclude_paths_extra`:** A separate key for user additions; the defaults are always present.

## Decision

Use **replace semantics** for v0.1. The default list (`node_modules`, `.git`, `vendor`, `.venv`, `dist`, `.next`, `.nuxt`, `build`, `__pycache__`) is shipped in `config.json`. When a user overrides `exclude_paths` in `.claude/settings.json`, they replace the entire list.

**Rationale:** The layered config merge (`jq * merge`) already uses replace semantics for arrays — this is consistent with how other plugin config arrays work (e.g., tribunal's `judge_types`). Introducing a separate `exclude_paths_extra` key adds surface area without clear demand in v0.1.

**Documented limitation:** Users who override `exclude_paths` and forget to include `node_modules` or `.git` will audit those directories. This is documented in the configuration reference.

## Consequences

- Config behavior is consistent with other plugin array keys.
- Users who want to extend must copy-paste the defaults plus their additions. This is mildly annoying but rare.

## Future Option

If users consistently request append behavior, `exclude_paths_extra` (a supplementary array that merges with the defaults) can be added in v0.2 without breaking existing configs.

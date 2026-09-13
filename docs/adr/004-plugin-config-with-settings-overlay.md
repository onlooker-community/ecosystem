# ADR-004: Per-Plugin Config with settings.json Overlay

**Status:** Accepted  
**Date:** 2026-05-24

## Context

Plugins need to be configurable. A developer working on a security-sensitive repo wants a tighter Tribunal gate policy; a developer on a fast-iteration project wants Echo to use a cheaper model. Several config models were available:

- **Single global config** — one file under `~/.onlooker/` controls everything.
- **Plugin-owned config only** — each plugin reads its own file; no user override path.
- **Separate per-project config files** — e.g., `.onlooker/echo.json`, `.onlooker/tribunal.json`.
- **Plugin defaults + settings.json overlay** — plugin ships `config.json` with defaults; users override via the standard Claude Code `settings.json` under a plugin-namespaced key.

## Decision

Each plugin ships `config.json` with defaults. Users override per-project in `.claude/settings.json` (or globally in `~/.claude/settings.json`) under the plugin's namespace key (e.g., `"echo"`, `"tribunal"`).

## Rationale

**`settings.json` is already the Claude Code config file.** Developers already open `.claude/settings.json` to configure permissions, hooks, and tools. Putting plugin config in the same file means one file to edit, one file to commit, one file to review in a PR. Introducing `.onlooker/echo.json` as a separate file creates fragmentation without benefit.

**Two levels cover the common cases without complexity.** Global (`~/.claude/settings.json`) sets your personal defaults — the model you prefer, your default drift threshold. Project-level (`.claude/settings.json`) overrides for the specific repo. Most plugin config systems need exactly these two scopes; adding more (team, org, workspace) introduces merging ambiguity.

**Plugin `config.json` is the source of truth for available knobs.** Every configurable key is documented in the plugin's `config.json` with its default value. Users browse the defaults to discover what's overridable. This is simpler than a separate schema document.

**Config loading is a thin bash function.** Each plugin ships a `*-config.sh` library (`echo_config_get`, `tribunal_config_get`, etc.) that reads the settings overlay first, falls back to plugin defaults. The pattern is consistent across plugins and is tested via bats.

## Consequences

- Plugin config keys must not collide with existing Claude Code top-level keys (`permissions`, `hooks`, `mcpServers`, `env`, etc.). Plugin namespaces (`"echo"`, `"tribunal"`, `"archivist"`) are chosen to avoid conflicts.
- Merge behavior is not yet uniform across plugins. Tribunal and Archivist use a recursive `deepmerge` (implemented in jq) so a user can override a single nested key without replacing the whole sub-object. Echo uses a simpler per-key lookup that falls back to plugin defaults. New plugins should use `deepmerge` for consistency.
- `config.json` is committed to the repo and ships with the plugin. It is not user-editable in place — users always override via `settings.json`. This prevents accidental plugin updates from overwriting user config.
- There is no validation that `settings.json` keys are recognized by the plugin. An unknown key silently does nothing. A future lint step could warn on unrecognized plugin config keys.
- Project-level layers 4 and 5 resolve against **different roots**. `.claude/settings.json` is committed and therefore branch-scoped, so it is read from the worktree the session is actually in; `.claude/settings.local.json` is gitignored and therefore machine-scoped, so `git worktree add` never copies it and it is read from the parent checkout. `config_load_plugin` takes a session cwd and derives both roots itself rather than accepting one — three bugs (`ecosystem-ber`, `ecosystem-68z`, `ecosystem-449.37`) all traced to a caller supplying a root that was silently wrong. Outside a git repo both roots fall back to the cwd, since `.claude/settings.json` is a Claude Code concept rather than a git one. See `docs/superpowers/specs/2026-09-13-config-root-resolution-design.md`.

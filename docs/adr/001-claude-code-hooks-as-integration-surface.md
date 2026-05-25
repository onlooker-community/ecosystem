# ADR-001: Claude Code Hooks as the Integration Surface

**Status:** Accepted  
**Date:** 2026-05-24

## Context

Onlooker needs to observe what happens inside a Claude Code session — when sessions start and end, what tools are called, when context compacts, and when the model produces output. Several integration approaches were available:

- **Claude Code hooks** — shell commands registered in `settings.json` that fire on lifecycle events (`SessionStart`, `Stop`, `PreCompact`, `PostToolUse`, `UserPromptSubmit`).
- **MCP server** — a Model Context Protocol server that Claude Code connects to; the server receives tool calls and can inject context.
- **Wrapper CLI** — a `claude` shim that intercepts invocations, records them, and delegates to the real binary.
- **IDE extension** — a VS Code or JetBrains extension that observes editor events.

## Decision

The ecosystem uses **Claude Code hooks** as the primary integration surface.

## Rationale

**First-class support.** Hooks are a documented, stable feature of Claude Code. They receive structured JSON on stdin and can inject `additionalContext` via stdout. This is not a workaround — it's the intended extension mechanism.

**No daemon required.** Hooks are short-lived shell processes. No persistent server, no port management, no process supervision. Each hook fires, does its work, and exits. This keeps the operational footprint near zero.

**Composable and auditable.** Hook registrations live in `settings.json` alongside permissions and tool config. A developer can inspect exactly which hooks are registered, enable or disable them per-project, and trace any hook's behavior by reading its shell script.

**Works across all Claude Code surfaces.** Hooks fire in the CLI, the desktop app, and IDE extensions. An MCP server or wrapper CLI would cover only the surfaces that honor those integrations.

**Shell is universally available.** Hooks are shell commands. The Onlooker substrate (bash, jq, node) is the only runtime requirement. An MCP server would require a language runtime and a persistent process to be managed.

## Why not MCP?

MCP is the right surface for extending Claude's *tool use* — adding new capabilities the model can call. It is not a good fit for *observing* what the model does. MCP servers cannot easily intercept session lifecycle events (start, stop, compact), and the connection model assumes a persistent server. Hooks handle lifecycle events natively and are stateless by design.

## Why not a wrapper CLI?

A `claude` shim breaks when users install Claude Code via paths the shim does not intercept (desktop app, IDE extension). It also requires the shim to be on PATH before the real binary, which is fragile across environments. Hooks require no PATH manipulation.

## Consequences

- All ecosystem behavior is implemented in shell scripts sourced from `scripts/hooks/` and `scripts/lib/`. Shell has limitations (no associative arrays on bash 3.2, string-only data model), but the constraints are well-understood and the code is readable without a language-specific toolchain.
- The hook event set is fixed by Claude Code. If an event that doesn't exist today is needed (e.g., a `PostCompact` or `ToolError` event), it cannot be added until Claude Code ships it.
- Hooks run synchronously in some cases (`UserPromptSubmit`, `Stop`) and must be fast or the user experience degrades. Long-running evaluations (Tribunal, Echo) use `claude -p` subprocesses and must carry a recursion guard.

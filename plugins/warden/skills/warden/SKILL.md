---
name: warden
description: Inspect and control the Warden content gate. Shows whether the session's content gate is open or closed and the threat that closed it (`/warden` or `/warden status`), and explicitly clears a closed gate to re-enable Write/Edit/Bash (`/warden clear`). Clearing is the only sanctioned way to reopen the gate — it records a user override in the warden.* event stream. Use when Warden has blocked a write/edit/bash operation, or when the user asks to check or clear the content gate.
---

# Warden: Content Gate Control

You are operating the **Warden** content gate — the user-facing control surface for the gate that Warden's hooks open and close automatically.

Warden enforces Meta's **Agents Rule of Two**: an agent should hold at most two of {access to private data, ability to take external actions, processing of untrusted content}. When Warden's detection hook finds an injection pattern in content ingested via WebFetch or Read, it closes a session-scoped gate that revokes the *external actions* property — blocking Write, Edit, MultiEdit, and Bash until the user explicitly clears it. This skill is that explicit clear (and a status readout).

## Parse the request

Read the user's argument after `/warden`:

- no argument, or `status` → **status** action
- `clear`, `reopen`, `override`, `unblock` → **clear** action

If the user passed a session id explicitly (rare), capture it as the optional second argument.

## Run the control surface

Source the plugin helpers and invoke `warden_cli`. Run this in a single bash call:

```bash
set -uo pipefail
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/warden-config.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/warden-events.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/warden-gate-state.sh"
source "$CLAUDE_PLUGIN_ROOT/scripts/lib/warden-cli.sh"

# action is "status" or "clear"; SESSION_ID_ARG is optional and usually empty.
warden_cli "<action>" "${SESSION_ID_ARG:-}"
```

`warden_cli` resolves the session automatically: it prefers `$CLAUDE_SESSION_ID`, falls back to the single closed gate if exactly one exists, and reports ambiguity if several sessions have closed gates (re-run with an explicit session id in that case).

## Behavior

- **status** — prints whether the gate is OPEN or CLOSED. When closed, prints the recorded threat: `threat_type`, `source_type`, source URL/path, confidence, detection method, matched pattern, and the flagged snippet (if storage is enabled).
- **clear** — verifies the gate is closed, removes the lock, and emits `warden.threat.cleared` with `cleared_by: user_override`. This re-enables Write/Edit/Bash for the session.

## After clearing

When you clear the gate on the user's behalf:

1. Confirm the gate is reopened and name the source that triggered it.
2. Remind the user briefly that the flagged content is still in the conversation context — clearing the gate does not remove it. If they have not reviewed the source, suggest they do before continuing with external actions.
3. Do not clear a gate the user has not asked you to clear. Closing is automatic; clearing is always a deliberate user decision.

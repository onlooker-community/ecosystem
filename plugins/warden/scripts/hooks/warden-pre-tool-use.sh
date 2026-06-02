#!/usr/bin/env bash
# Warden PreToolUse hook — enforcement path for Write, Edit, MultiEdit, Bash.
#
# Tool-agnostic gate check: if this session's content gate is closed, block
# the operation and tell the user how to clear it. Otherwise allow silently.
# No LLM call, no parsing — just a lock check, so it is fast and trivially
# fail-closed (a present lock always blocks).
#
# Hook contract (Claude Code PreToolUse protocol):
#   - Always exits 0.
#   - To block: write {"decision":"block","reason":"..."} to stdout.
#   - To allow: write nothing to stdout.
#   - Errors are written to stderr only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/warden-config.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-config.sh"
# shellcheck source=../lib/warden-events.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-events.sh"
# shellcheck source=../lib/warden-gate-state.sh
source "${PLUGIN_ROOT}/scripts/lib/warden-gate-state.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL_NAME=""

export _HOOK_SESSION_ID="$SESSION_ID"

warden_config_load "$CWD"

if ! warden_config_enabled; then
	exit 0
fi

[[ -z "$SESSION_ID" ]] && exit 0

# Gate open → allow silently.
if ! warden_gate_is_closed "$SESSION_ID"; then
	exit 0
fi

# ---- Gate closed → block this operation. -----------------------------
# Map the tool to the schema's blocked_operation enum.
case "$TOOL_NAME" in
	Write)              BLOCKED_OP="tool.file.write" ;;
	Edit|MultiEdit)     BLOCKED_OP="tool.file.edit" ;;
	Bash)               BLOCKED_OP="tool.shell.exec" ;;
	*)                  BLOCKED_OP="tool.file.write" ;;
esac

THREAT=$(warden_gate_threat "$SESSION_ID") || THREAT=""
THREAT_SOURCE_TYPE=$(printf '%s' "$THREAT" | jq -r '.source_type // "web_fetch"' 2>/dev/null) || THREAT_SOURCE_TYPE="web_fetch"
THREAT_TYPE=$(printf '%s' "$THREAT" | jq -r '.threat_type // "prompt_injection"' 2>/dev/null) || THREAT_TYPE="prompt_injection"
THREAT_SOURCE=$(printf '%s' "$THREAT" | jq -r '.source_url // .source_path // "(unknown source)"' 2>/dev/null) || THREAT_SOURCE="(unknown source)"
THREAT_SNIPPET=$(printf '%s' "$THREAT" | jq -r '.snippet // ""' 2>/dev/null) || THREAT_SNIPPET=""

# Emit warden.gate.blocked (schema-permitted fields only).
EVENT_PAYLOAD=$(jq -n \
	--arg op "$BLOCKED_OP" \
	--arg st "$THREAT_SOURCE_TYPE" \
	'{blocked_operation:$op, threat_source_type:$st}' 2>/dev/null) || EVENT_PAYLOAD=""
[[ -n "$EVENT_PAYLOAD" ]] && warden_emit_event "warden.gate.blocked" "$EVENT_PAYLOAD" || true

# Build the block message.
SNIPPET_LINE=""
[[ -n "$THREAT_SNIPPET" ]] && SNIPPET_LINE=$(printf '\n  Flagged excerpt: %s' "$THREAT_SNIPPET")

MESSAGE=$(printf \
'Warden closed the content gate — external actions are paused.

A %s threat was detected in untrusted content from %s (%s).
Under the Agents Rule of Two, warden has revoked the "external actions"
property while that content is in your context: Write, Edit, and Bash are
blocked until you clear the gate.%s

To proceed:
  • Review the flagged source, then run  /warden clear  to reopen the gate.
  • Run  /warden status  to see the full threat record.
  • If this was a false positive, /warden clear records your override.' \
	"$THREAT_TYPE" "$THREAT_SOURCE" "$THREAT_SOURCE_TYPE" "$SNIPPET_LINE")

jq -n \
	--arg message "$MESSAGE" \
	'{"decision":"block","reason":$message}' 2>/dev/null \
	|| printf '{"decision":"block","reason":"Warden closed the content gate. Run /warden clear to reopen."}'

exit 0

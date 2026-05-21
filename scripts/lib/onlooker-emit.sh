#!/usr/bin/env bash
# onlooker-emit.sh - Legacy shim: emit canonical events via @onlooker-community/schema.
#
# Prefer onlooker_emit_from_hook / onlooker_append_event from onlooker-schema.sh.
#
# Usage:
#   onlooker-emit.sh "tool.agent.spawn" '{"subagent_id":"x",...}'
#
# The first argument is treated as event_type; payload must match schema for that type.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate-path.sh
source "$SCRIPT_DIR/validate-path.sh"
# shellcheck source=onlooker-schema.sh
source "$SCRIPT_DIR/onlooker-schema.sh"

EVENT_TYPE="$1"
PAYLOAD_JSON="$2"

SESSION_ID="${_HOOK_SESSION_ID:-}"
if [[ -z "$SESSION_ID" ]]; then
	SESSION_ID=$(echo "$PAYLOAD_JSON" | jq -r '.session_id // "unknown"' 2>/dev/null) || SESSION_ID="unknown"
fi

PARAMS=$(jq -n \
	--arg plugin "${ONLOOKER_PLUGIN_NAME:-onlooker}" \
	--arg sid "$SESSION_ID" \
	--arg type "$EVENT_TYPE" \
	--argjson payload "$PAYLOAD_JSON" \
	'{plugin: $plugin, session_id: $sid, event_type: $type, payload: $payload}')

EVENT=$(printf '%s' "$PARAMS" | ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="$ONLOOKER_PLUGIN_NAME" \
	node "$_ONLOOKER_EVENT_JS" emit 2>/dev/null) || {
	hook_failure "Failed to build canonical event"
	exit 0
}

onlooker_append_event "$EVENT"
hook_success
exit 0

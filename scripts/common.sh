#!/usr/bin/env bash
# Shared helpers for Onlooker hook scripts.
# Requires validate-path.sh and onlooker-schema.sh.

# Emit canonical tool.agent.spawn telemetry event (schema payload).
# Usage: onlooker_emit_tool_agent_spawn SESSION_ID SUBAGENT_TYPE DESCRIPTION MODEL RUN_IN_BACKGROUND ISOLATION
onlooker_emit_tool_agent_spawn() {
	local session_id="$1"
	local subagent_type="$2"
	local description="$3"
	local _model="$4"
	local _run_in_background="$5"
	local _isolation="$6"

	local subagent_id="${session_id}-$(date +%s)"

	local params
	params=$(jq -n \
		--arg plugin "${ONLOOKER_PLUGIN_NAME:-onlooker}" \
		--arg sid "$session_id" \
		--arg subagent_id "$subagent_id" \
		--arg agent_name "$subagent_type" \
		--arg task_summary "$description" \
		'{
			plugin: $plugin,
			session_id: $sid,
			event_type: "tool.agent.spawn",
			payload: {
				subagent_id: $subagent_id,
				agent_name: $agent_name,
				task_summary: $task_summary
			}
		}')

	local event
	event=$(printf '%s' "$params" | ONLOOKER_DIR="$ONLOOKER_DIR" ONLOOKER_PLUGIN_NAME="$ONLOOKER_PLUGIN_NAME" \
		node "${CLAUDE_PLUGIN_ROOT}/scripts/lib/onlooker-event.mjs" emit 2>/dev/null) || return 1

	onlooker_append_event "$event"
}

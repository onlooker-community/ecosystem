#!/usr/bin/env bash
# What plugin code is this session actually running?
#
# ecosystem-9eg. installed_plugins.json reports what is on DISK. A session runs
# what was pinned when its PROCESS started, and /clear mints a new session_id
# inside the same process without reloading anything — so a cleared session
# looks post-release by every timestamp available while running pre-release
# code. Answering from the manifest, or from any timestamp comparison, gets
# this wrong. This reads what hooks actually reported.
#
# Usage:
#   scripts/session-plugin-versions.sh              # this session's host process
#   scripts/session-plugin-versions.sh --pid 1234   # a specific host process

set -uo pipefail

HEALTH_LOG="${ONLOOKER_HOOK_HEALTH_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/hook-health.jsonl}"

# Walk up the process tree to the nearest claude ancestor. A hook records its
# own $PPID, which is that process, so this is what joins us to the rows.
_resolve_host_pid() {
	local pid="$$" comm guard=0
	while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && "$guard" -lt 40 ]]; do
		comm=$(ps -o comm= -p "$pid" 2>/dev/null)
		case "$comm" in
			*claude*)
				printf '%s' "$pid"
				return 0
				;;
		esac
		pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
		guard=$((guard + 1))
	done
	return 1
}

HOST_PID=""
if [[ "${1:-}" == "--pid" ]]; then
	HOST_PID="${2:-}"
fi
if [[ -z "$HOST_PID" ]]; then
	HOST_PID=$(_resolve_host_pid) || {
		printf 'could not find a claude process in this process tree\n'
		exit 0
	}
fi

if [[ ! -f "$HEALTH_LOG" ]]; then
	printf 'no hook-health log at %s\n' "$HEALTH_LOG"
	exit 0
fi

OUT=$(jq -r --argjson pid "$HOST_PID" '
	select(.host_pid == $pid)
	| select(.plugin_name != null)
	| "\(.plugin_name) \(.plugin_version // "(working tree)")"
' "$HEALTH_LOG" 2>/dev/null | sort -u)

if [[ -z "$OUT" ]]; then
	printf 'no hook-health rows for host pid %s\n' "$HOST_PID"
	exit 0
fi

printf 'host pid %s is running:\n' "$HOST_PID"
printf '%s\n' "$OUT"

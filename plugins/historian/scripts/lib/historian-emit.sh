#!/usr/bin/env bash
# Event emission helpers for Historian.
#
# Thin wrapper around onlooker-event.mjs `emit` mode for historian.* events.
# Fail-soft: returns 0 on success or when the substrate is unavailable.

_historian_resolve_event_js() {
	local script_dir plugin_root sibling version_dir version mjs best_version best_path
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	plugin_root="$(cd "${script_dir}/../.." && pwd)"

	if [[ -n "${ONLOOKER_ECOSYSTEM_ROOT:-}" ]]; then
		printf '%s/scripts/lib/onlooker-event.mjs' "$ONLOOKER_ECOSYSTEM_ROOT"
		return 0
	fi

	sibling="$(cd "${plugin_root}/../.." 2>/dev/null && pwd)"
	if [[ -f "${sibling}/scripts/lib/onlooker-event.mjs" ]]; then
		printf '%s/scripts/lib/onlooker-event.mjs' "$sibling"
		return 0
	fi

	# Glob-discover the ecosystem plugin under the shared plugin cache parent;
	# works regardless of which ecosystem version is installed.
	#
	# Return the matched path itself. Re-deriving an ecosystem root from it
	# needs three dirnames, not two, and the two-dirname form doubled the
	# path to <v>/scripts/scripts/lib and silenced this plugin for 34 days
	# (ecosystem-449.34). Nothing here reconstructs what the glob already knows.
	#
	# Glob order is lexical and lexical order is not version order: 0.33.1
	# sorts ahead of 0.49.2, 0.9.0 sorts after both, and 0.47.9 sorts after
	# 0.47.10. Compare the version directories field by field as numbers so
	# the newest install wins regardless of how many are cached.
	best_version=""
	best_path=""
	for version_dir in "${plugin_root}/../../ecosystem/"*/; do
		version_dir="${version_dir%/}"
		mjs="${version_dir}/scripts/lib/onlooker-event.mjs"
		[[ -f "$mjs" ]] || continue
		version="${version_dir##*/}"
		if [[ -z "$best_version" ]] || [[ "$(printf '%s\n%s\n' "$best_version" "$version" |
			sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$version" ]]; then
			best_version="$version"
			best_path="$mjs"
		fi
	done

	if [[ -n "$best_path" ]]; then
		printf '%s' "$best_path"
	fi
}

_HISTORIAN_EVENT_JS="${_HISTORIAN_EVENT_JS:-$(_historian_resolve_event_js)}"

# Emit a historian.* event. Fail-soft: returns 0 on any error.
# Usage: historian_emit <event_type> <session_id> <payload_json>
historian_emit() {
	local event_type="${1:-}"
	local session_id="${2:-}"
	local payload="${3:-}"
	[ -z "$payload" ] && payload='{}'

	[[ -z "$event_type" || -z "$session_id" ]] && return 0
	[[ -z "$_HISTORIAN_EVENT_JS" || ! -f "$_HISTORIAN_EVENT_JS" ]] && return 0
	command -v node >/dev/null 2>&1 || return 0

	local params event_json
	params=$(jq -cn \
		--arg plugin "historian" \
		--arg session_id "$session_id" \
		--arg event_type "$event_type" \
		--argjson payload "$payload" \
		'{
			plugin: $plugin,
			session_id: $session_id,
			event_type: $event_type,
			payload: $payload
		}') || return 0

	event_json=$(
		ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}" \
		ONLOOKER_PLUGIN_NAME="historian" \
		printf '%s' "$params" | node "$_HISTORIAN_EVENT_JS" emit 2>/dev/null
	) || return 0
	[[ -z "$event_json" ]] && return 0

	# Default the sink rather than bailing on an unset one, the shape
	# archivist-events.sh:91 already uses. ONLOOKER_EVENTS_LOG is exported by
	# validate-path.sh, which a hook sources out of the ecosystem substrate --
	# so requiring it made substrate resolution load-bearing for emission twice
	# over, and turned a path defect into 34 days of silence (ecosystem-449.34).
	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	mkdir -p "$(dirname "$log_path")" 2>/dev/null
	printf '%s\n' "$event_json" >> "$log_path" 2>/dev/null
}

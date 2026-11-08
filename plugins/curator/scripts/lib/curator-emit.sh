#!/usr/bin/env bash
# Event emission helpers for Curator.
#
# Thin wrapper around onlooker-event.mjs `emit` mode for curator.* events.
# Fail-soft: returns 0 on success or when the substrate is unavailable.

# Vendored substrate resolver, located from this file's own path and tolerated
# absent — see substrate-resolve.sh, "FAIL-SOFT CALLERS", for why both.
_CURATOR_EMIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_CURATOR_EMIT_LIB_DIR}/substrate-resolve.sh" ]]; then
	# shellcheck source=plugins/curator/scripts/lib/substrate-resolve.sh
	source "${_CURATOR_EMIT_LIB_DIR}/substrate-resolve.sh"
fi

# Resolve onlooker-event.mjs in the newest cached ecosystem. Honors
# ONLOOKER_ECOSYSTEM_ROOT (test isolation) and a sibling checkout, both via
# the resolver.
#
# This used to walk the cache itself, comparing versions pairwise with a
# `printf | sort | tail` per cached ecosystem, and it ran when the lib was
# sourced. At 47 cached versions that was ~140ms on every hook that sourced
# it, emitting or not, growing with each release (ONL-271). The resolver
# orders the whole glob in one sort; this lib only appends the filename.
_curator_resolve_event_js() {
	local root=""
	if declare -F onlooker_resolve_substrate >/dev/null 2>&1; then
		root="$(onlooker_resolve_substrate "$(cd "${_CURATOR_EMIT_LIB_DIR}/../.." && pwd)")"
	fi
	if [[ -n "$root" && -f "${root}/scripts/lib/onlooker-event.mjs" ]]; then
		printf '%s/scripts/lib/onlooker-event.mjs' "$root"
	fi
}

# Resolved on the first emit rather than here: most runs of the hooks that
# source this emit nothing. A preset value (tests) is used as-is.
_CURATOR_EVENT_JS="${_CURATOR_EVENT_JS:-}"

# Emit a curator.* event. Fail-soft: returns 0 on any error.
# Usage: curator_emit <event_type> <session_id> <payload_json>
curator_emit() {
	local event_type="${1:-}"
	local session_id="${2:-}"
	local payload="${3:-}"
	[ -z "$payload" ] && payload='{}'

	[[ -z "$event_type" || -z "$session_id" ]] && return 0
	[[ -n "$_CURATOR_EVENT_JS" ]] || _CURATOR_EVENT_JS="$(_curator_resolve_event_js)"
	[[ -z "$_CURATOR_EVENT_JS" || ! -f "$_CURATOR_EVENT_JS" ]] && return 0
	command -v node >/dev/null 2>&1 || return 0

	local params event_json
	params=$(jq -cn \
		--arg plugin "curator" \
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
		ONLOOKER_PLUGIN_NAME="curator" \
		printf '%s' "$params" | node "$_CURATOR_EVENT_JS" emit 2>/dev/null
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

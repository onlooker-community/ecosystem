#!/usr/bin/env bash
# cartographer-events.sh — emit cartographer.* events to the canonical event log.
#
# Thin wrapper around onlooker-event.mjs. Validation failures are logged to
# stderr and do not abort the caller — Cartographer is advisory.
#
# Usage:
#   cartographer_emit_event "cartographer.audit.complete" '{"audit_id":"...","new_finding_count":2}'

_CARTOGRAPHER_PLUGIN_NAME="cartographer"

_cartographer_event_js_path() {
	if [[ -n "${_ONLOOKER_EVENT_JS:-}" && -f "$_ONLOOKER_EVENT_JS" ]]; then
		printf '%s' "$_ONLOOKER_EVENT_JS"
		return 0
	fi
	local plugin_root="${CLAUDE_PLUGIN_ROOT:-}"
	local candidates=(
		"${plugin_root}/scripts/lib/onlooker-event.mjs"
		"${plugin_root}/../../scripts/lib/onlooker-event.mjs"
	)
	local c
	for c in "${candidates[@]}"; do
		[[ -f "$c" ]] && { printf '%s' "$c"; return 0; }
	done
	# Glob-discover the ecosystem plugin under the shared plugin cache parent;
	# works regardless of which ecosystem version is installed.
	local mjs
	for mjs in "${plugin_root}/../../ecosystem/"*/scripts/lib/onlooker-event.mjs; do
		[[ -f "$mjs" ]] && { printf '%s' "$mjs"; return 0; }
	done
	return 1
}

_cartographer_session_id() {
	if [[ -n "${_HOOK_SESSION_ID:-}" ]]; then
		printf '%s' "$_HOOK_SESSION_ID"
		return 0
	fi
	if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		printf '%s' "$CLAUDE_SESSION_ID"
		return 0
	fi
	printf 'unknown'
}

# Build the cartographer.issue.found payload for one finding record.
#
# Lives here rather than inline in run_emit so the test suite drives the same
# construction production does. Two independent descriptions of one payload is
# precisely how the published schema came to document events no code had ever
# emitted; a single builder means a test that passes is evidence about the real
# emission path, not about a copy of it.
#
# Usage: cartographer_issue_found_payload <audit_id> <finding_hash> <finding_json>
cartographer_issue_found_payload() {
	local audit_id="${1:-}" finding_hash="${2:-}" finding="${3:-}"
	[[ -z "$audit_id" || -z "$finding_hash" || -z "$finding" ]] && return 1

	local ftype fseverity ffile_a ffile_b fdesc
	ftype=$(printf '%s' "$finding" | jq -r '.type // "unknown"')
	fseverity=$(printf '%s' "$finding" | jq -r '.severity // "warning"')
	ffile_a=$(printf '%s' "$finding" | jq -r '.file_a // ""')
	ffile_b=$(printf '%s' "$finding" | jq -r '.file_b // null')
	fdesc=$(printf '%s' "$finding" | jq -r '.description // ""')

	jq -n \
		--arg audit_id "$audit_id" \
		--arg finding_hash "$finding_hash" \
		--arg finding_type "$ftype" \
		--arg severity "$fseverity" \
		--argjson affected_files "$(jq -n --arg a "$ffile_a" --arg b "$ffile_b" \
			'if $b == "null" or $b == "" then [$a] else [$a,$b] end')" \
		--arg summary "$fdesc" \
		'{"audit_id":$audit_id,"finding_hash":$finding_hash,"finding_type":$finding_type,"severity":$severity,"affected_files":$affected_files,"summary":$summary}'
}

# Build the cartographer.audit.complete payload for a finished run.
#
# Usage: cartographer_audit_complete_payload <audit_id> <trigger> <new_count> <total_count> <duration_ms>
cartographer_audit_complete_payload() {
	local audit_id="${1:-}" trigger="${2:-}"
	local new_count="${3:-0}" total_count="${4:-0}" duration_ms="${5:-0}"
	[[ -z "$audit_id" ]] && return 1

	jq -n \
		--arg audit_id "$audit_id" \
		--arg trigger "$trigger" \
		--argjson new_finding_count "$new_count" \
		--argjson total_finding_count "$total_count" \
		--argjson duration_ms "$duration_ms" \
		'{"audit_id":$audit_id,"trigger":$trigger,"new_finding_count":$new_finding_count,"total_finding_count":$total_finding_count,"duration_ms":$duration_ms}'
}

cartographer_emit_event() {
	local event_type="${1:-}"
	local payload="${2:-}"
	[[ -z "$event_type" || -z "$payload" ]] && return 1

	local event_js
	event_js=$(_cartographer_event_js_path) || {
		printf 'cartographer-events: cannot locate onlooker-event.mjs\n' >&2
		return 1
	}

	local session_id
	session_id=$(_cartographer_session_id)

	local params
	params=$(jq -n \
		--arg plugin "$_CARTOGRAPHER_PLUGIN_NAME" \
		--arg sid "$session_id" \
		--arg type "$event_type" \
		--argjson payload "$payload" \
		'{"plugin":$plugin,"session_id":$sid,"event_type":$type,"payload":$payload}')

	local stderr_file
	stderr_file=$(mktemp -t cartographer-event-err.XXXXXX 2>/dev/null) \
		|| stderr_file="/tmp/cartographer-event-err.$$"

	local event
	event=$(printf '%s' "$params" \
		| ONLOOKER_DIR="${ONLOOKER_DIR:-$HOME/.onlooker}" \
		  ONLOOKER_PLUGIN_NAME="$_CARTOGRAPHER_PLUGIN_NAME" \
		  node "$event_js" emit 2>"$stderr_file") || {
		printf 'cartographer-events: schema validation failed for %s\n' "$event_type" >&2
		[[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
		rm -f "$stderr_file"
		return 1
	}
	rm -f "$stderr_file"

	local log_path="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/onlooker-events.jsonl}"
	mkdir -p "$(dirname "$log_path")" 2>/dev/null || return 1
	printf '%s\n' "$event" >>"$log_path"
}

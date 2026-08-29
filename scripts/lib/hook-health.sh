#!/usr/bin/env bash
# Hook execution timing for Onlooker hooks — ecosystem substrate and plugins.
#
# This file is VENDORED into every plugin's scripts/lib/. Edit this canonical
# copy and run scripts/sync-shared-libs.sh to propagate it; drift is caught by
# test/bats/shared-lib-vendoring.bats.
#
# It is deliberately self-contained. A plugin publishes rooted at
# plugins/<name> and ships no ecosystem tree, so this file may not source
# validate-path.sh or anything else (ecosystem-ber).
#
# Usage, at the top of a hook:
#   source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
#   hook_health_register "my-plugin-post-tool-use"
#   INPUT=$(cat)
#   hook_health_context "$INPUT"
#
# Fail-soft throughout: every function returns 0. A hook must never break
# because its instrument broke.

# Do not clobber values a caller already set — several plugins set
# _HOOK_SESSION_ID before sourcing, and their *-events.sh libs read it.
_HOOK_NAME="${_HOOK_NAME:-}"
_HOOK_START_MS="${_HOOK_START_MS:-}"
_HOOK_SESSION_ID="${_HOOK_SESSION_ID:-}"
_HOOK_EVENT="${_HOOK_EVENT:-}"
_HOOK_TOOL_NAME="${_HOOK_TOOL_NAME:-}"

hook_health_log_path() {
	printf '%s' "${ONLOOKER_HOOK_HEALTH_LOG:-${ONLOOKER_DIR:-$HOME/.onlooker}/logs/hook-health.jsonl}"
}

# Milliseconds since the epoch, cheapest source first.
#
# Cost measured on macOS: $EPOCHREALTIME 0.08ms, perl 6.9ms, python3 18.7ms.
# Hooks run under bash 3.2, where EPOCHREALTIME does not exist, so perl is the
# usual winner. The date rung gives second resolution rather than dropping the
# record entirely.
_hook_health_now_ms() {
	local er s us
	if [[ -n "${EPOCHREALTIME:-}" ]]; then
		er="${EPOCHREALTIME/,/.}"   # some locales render the separator as a comma
		s="${er%%.*}"
		us="${er#*.}000"
		printf '%s%s' "$s" "${us:0:3}"
		return 0
	fi
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time() * 1000' 2>/dev/null && return 0
	fi
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null && return 0
	fi
	printf '%s000' "$(date +%s 2>/dev/null || printf 0)"
}

# Start timing. Call as early in the hook as possible.
hook_health_register() {
	_HOOK_NAME="${1:-unknown}"
	_HOOK_START_MS=$(_hook_health_now_ms)
	return 0
}

# Fill session/event/tool from the hook's JSON payload. Optional — call it
# after reading stdin. Values already set by the caller win, so a hook that
# assigned _HOOK_SESSION_ID itself keeps its value.
hook_health_context() {
	local input="${1:-}"
	[[ -n "$input" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	[[ -z "$_HOOK_SESSION_ID" ]] && _HOOK_SESSION_ID=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null)
	[[ -z "$_HOOK_TOOL_NAME" ]] && _HOOK_TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
	[[ -z "$_HOOK_EVENT" ]] && _HOOK_EVENT=$(printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null)
	return 0
}

hook_health_success() {
	_hook_health_write "success" ""
}

hook_health_failure() {
	_hook_health_write "failure" "${1:-}"
}

# Write one record. The end timestamp comes from jq's `now` inside the call we
# already make, so it costs no extra process.
_hook_health_write() {
	local hook_status="$1"
	local error_msg="$2"

	[[ -n "$_HOOK_NAME" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	local path
	path=$(hook_health_log_path)
	mkdir -p "$(dirname "$path")" 2>/dev/null || return 0

	local start="${_HOOK_START_MS:-0}"
	[[ "$start" =~ ^[0-9]+$ ]] || start=0

	jq -cn \
		--arg hook "$_HOOK_NAME" \
		--arg hook_status "$hook_status" \
		--arg error "$error_msg" \
		--arg session_id "$_HOOK_SESSION_ID" \
		--arg hook_event "$_HOOK_EVENT" \
		--arg tool_name "$_HOOK_TOOL_NAME" \
		--argjson start "$start" \
		'(now * 1000 | floor) as $end
		 | {
			timestamp: (now | todate),
			hook: $hook,
			status: $hook_status,
			duration_ms: (if $start > 0 and $end > $start then $end - $start else 0 end),
			error: (if $error == "" then null else $error end),
			session_id: (if $session_id == "" then null else $session_id end),
			hook_event: (if $hook_event == "" then null else $hook_event end),
			tool_name: (if $tool_name == "" then null else $tool_name end)
		   }' >> "$path" 2>/dev/null || true

	# Reset so a second write in the same shell cannot double-count.
	_HOOK_NAME=""
	_HOOK_START_MS=""
	return 0
}

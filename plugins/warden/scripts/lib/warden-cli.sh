#!/usr/bin/env bash
# Interactive control surface for the /warden skill.
#
# Exposes:
#   warden_cli status [session_id]   # print the gate state + threat record
#   warden_cli clear  [session_id]   # explicit user override: reopen the gate
#
# Session resolution order:
#   1. explicit session_id argument
#   2. $CLAUDE_SESSION_ID (when its gate is closed)
#   3. the single closed gate, if exactly one exists
#   4. otherwise: report ambiguity / no closed gate and do nothing
#
# Depends on (sourced by the caller): warden-gate-state.sh · warden-events.sh

# Resolve the session whose gate the command should act on.
# Echoes the session id, or empty. Second arg "require_closed" (default true)
# restricts auto-resolution to sessions with a closed gate.
_warden_cli_resolve_session() {
	local explicit="${1:-}"

	if [[ -n "$explicit" ]]; then
		printf '%s' "$explicit"
		return 0
	fi

	if [[ -n "${CLAUDE_SESSION_ID:-}" ]] && warden_gate_is_closed "$CLAUDE_SESSION_ID"; then
		printf '%s' "$CLAUDE_SESSION_ID"
		return 0
	fi

	# bash 3.2 (macOS default) has no `mapfile`; collect with a while-read loop.
	local closed=() line
	while IFS= read -r line; do
		[[ -n "$line" ]] && closed+=("$line")
	done < <(warden_list_closed_sessions)
	if [[ "${#closed[@]}" -eq 1 ]]; then
		printf '%s' "${closed[0]}"
		return 0
	fi

	# Fall back to the current session id even if its gate is open, so status
	# can report "open" for the right session.
	if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		printf '%s' "$CLAUDE_SESSION_ID"
		return 0
	fi

	printf ''
	return 1
}

warden_cli() {
	local action="${1:-status}"
	local session_arg="${2:-}"

	local session_id
	session_id=$(_warden_cli_resolve_session "$session_arg") || session_id=""

	# Report ambiguity when multiple gates are closed and none was specified.
	if [[ -z "$session_id" ]]; then
		local closed=() line
		while IFS= read -r line; do
			[[ -n "$line" ]] && closed+=("$line")
		done < <(warden_list_closed_sessions)
		if [[ "${#closed[@]}" -gt 1 ]]; then
			printf 'Multiple sessions have a closed gate. Re-run with an explicit session id:\n'
			printf '  %s\n' "${closed[@]}"
			return 0
		fi
		printf 'No closed gate found and no session id available.\n'
		return 0
	fi

	case "$action" in
		status)
			if warden_gate_is_closed "$session_id"; then
				local threat
				threat=$(warden_gate_threat "$session_id")
				printf 'Gate: CLOSED (session %s)\n\n' "$session_id"
				printf '%s\n' "$threat" | jq -r '
					"  threat_type:     \(.threat_type // "unknown")",
					"  source_type:     \(.source_type // "unknown")",
					"  source:          \(.source_url // .source_path // "(unknown)")",
					"  confidence:      \(.confidence // "n/a")",
					"  detection:       \(.detection_method // "unknown")",
					"  matched_pattern: \(.matched_pattern // "n/a")",
					"  snippet:         \(.snippet // "(not stored)")"
				' 2>/dev/null || printf '  (threat record unavailable)\n'
				printf '\nRun  /warden clear  to reopen the gate (records a user override).\n'
			else
				printf 'Gate: OPEN (session %s) — no active threat. Write, Edit, and Bash are allowed.\n' "$session_id"
			fi
			;;
		clear)
			if ! warden_gate_is_closed "$session_id"; then
				printf 'Gate already OPEN (session %s) — nothing to clear.\n' "$session_id"
				return 0
			fi
			local prior_threat source_type
			prior_threat=$(warden_gate_threat "$session_id")
			source_type=$(printf '%s' "$prior_threat" | jq -r '.source_type // "web_fetch"' 2>/dev/null) || source_type="web_fetch"

			warden_gate_clear "$session_id" >/dev/null || {
				printf 'Failed to clear the gate for session %s.\n' "$session_id"
				return 1
			}

			# Emit warden.threat.cleared (schema-permitted fields only).
			local payload
			payload=$(jq -n --arg st "$source_type" \
				'{source_type:$st, cleared_by:"user_override"}' 2>/dev/null) || payload=""
			if [[ -n "$payload" ]]; then
				_HOOK_SESSION_ID="$session_id" warden_emit_event "warden.threat.cleared" "$payload" || true
			fi

			printf 'Gate CLEARED (session %s). External actions re-enabled by user override.\n' "$session_id"
			;;
		*)
			printf 'Unknown action "%s". Use: status | clear\n' "$action"
			return 1
			;;
	esac
}

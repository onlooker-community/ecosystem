#!/usr/bin/env bash
# Customs PreToolUse hook - the outbound secret gate for Bash and WebFetch.
#
# One question per call: is a secret-shaped literal in this call headed to a
# host that is not where that kind of secret goes? Design and reasoning:
# docs/superpowers/specs/2026-10-25-customs-outbound-gate-design.md.
#
# Hook contract (Claude Code PreToolUse protocol):
#   - Always exits 0.
#   - To ask or deny: write a hookSpecificOutput payload with
#     permissionDecision "ask" or "deny". Pinned by gate-block-contract.bats.
#   - To pass: write nothing. Customs never writes "allow", so it can add a
#     prompt to a call another gate allowed but can never loosen one.
#
# FAILS OPEN, the reverse of onlooker-secret-patterns.sh. That lib fails closed
# because a redactor that fails open writes the secret to disk. A gate on every
# Bash call that failed closed would turn a missing python3 into a session
# where no shell command runs, and the likely response is to disable customs
# entirely. Every failure emits customs.check.failed naming its stage, so a
# broken customs reads as failed on the Sessions page, never as quiet.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "customs-pre-tool-use"

# shellcheck source=../lib/customs-config.sh
source "${PLUGIN_ROOT}/scripts/lib/customs-config.sh"
# shellcheck source=../lib/customs-events.sh
source "${PLUGIN_ROOT}/scripts/lib/customs-events.sh"
# shellcheck source=../lib/customs-destination.sh
source "${PLUGIN_ROOT}/scripts/lib/customs-destination.sh"
# shellcheck source=../lib/customs-allowlist.sh
source "${PLUGIN_ROOT}/scripts/lib/customs-allowlist.sh"
# shellcheck source=../lib/onlooker-secret-patterns.sh
source "${PLUGIN_ROOT}/scripts/lib/onlooker-secret-patterns.sh"

TOOL_NAME=""

_customs_record_failure() {
	local stage="$1" payload=""
	if [[ "$TOOL_NAME" == "Bash" || "$TOOL_NAME" == "WebFetch" ]]; then
		payload=$(jq -cn --arg t "$TOOL_NAME" --arg s "$stage" '{tool: $t, stage: $s}' 2>/dev/null)
	else
		payload=$(jq -cn --arg s "$stage" '{stage: $s}' 2>/dev/null)
	fi
	[[ -n "$payload" ]] && { customs_emit_event "customs.check.failed" "$payload" || true; }
	return 0
}

_customs_fail_open() {
	_customs_record_failure "$1"
	hook_health_exit 0
}

INPUT=$(cat)
hook_health_context "$INPUT"

printf '%s' "$INPUT" | jq -e 'type == "object"' >/dev/null 2>&1 || _customs_fail_open "input"
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""')
export _HOOK_SESSION_ID="$SESSION_ID"

case "$TOOL_NAME" in
	Bash)     TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""') ;;
	WebFetch) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.url // ""') ;;
	*)        hook_health_exit 0 ;;
esac
[[ -z "$TEXT" ]] && hook_health_exit 0

# The common path. A Bash call that runs no network tool ends here, before
# python3 starts: customs guards egress, not storage.
if [[ "$TOOL_NAME" == "Bash" ]] && ! customs_has_network_tool "$TEXT"; then
	hook_health_exit 0
fi

DETECTED=$(onlooker_detect_secrets "$(jq -cn --arg s "$TEXT" '[$s]')" 2>/dev/null)
KINDS=$(printf '%s' "$DETECTED" | jq -c '.[0].kinds | arrays' 2>/dev/null)
[[ -z "$KINDS" ]] && _customs_fail_open "detect"
[[ "$KINDS" == "[]" ]] && hook_health_exit 0

HOST_LINES=$(customs_destination_hosts "$TOOL_NAME" "$TEXT")
HOST_STATUS=$?
HOSTS_ALL=$(printf '%s' "$HOST_LINES" | jq -R . | jq -sc 'map(select(length > 0))' 2>/dev/null)
[[ -z "$HOSTS_ALL" ]] && _customs_fail_open "destination"
# The cap bounds the event only, never the decision: a host past the 16th must
# still reach customs_decide.
HOSTS=$(printf '%s' "$HOSTS_ALL" | jq -c '.[:16]')
# Exit 2: a candidate customs could not read (or one shaped like a secret), a
# network command that named no readable host, or a WebFetch URL a URL parser
# would read differently. It is decided as if no host were readable, so an
# allowed host beside it cannot carry the call through. The event still lists
# the hosts that were read.
DECIDE_HOSTS="$HOSTS_ALL"
[[ "$HOST_STATUS" -eq 2 ]] && DECIDE_HOSTS='[]'

customs_config_load "$CWD"
MODE=$(customs_config_get '.customs.mode')
if [[ "$MODE" != "ask" && "$MODE" != "deny" ]]; then
	# Spec, "Config": anything else asks, and says the config was wrong.
	_customs_record_failure "config"
	MODE="ask"
fi
USER_PAIRS=$(customs_config_get_json '.customs.pairs')
RECORD_ONLY=$(customs_config_get_json '.customs.record_only_kinds')

DECISION=$(customs_decide "$KINDS" "$DECIDE_HOSTS" "$USER_PAIRS" "$RECORD_ONLY" 2>/dev/null)

# $1 is the jq filter, $2 the decision (flagged only).
_customs_payload() {
	jq -cn --arg t "$TOOL_NAME" --argjson k "$KINDS" --argjson h "$HOSTS" \
		--arg d "${2:-}" "$1"
}

case "$DECISION" in
	allow)
		customs_emit_event "customs.egress.allowed" \
			"$(_customs_payload '{tool: $t, kinds: $k, hosts: $h}')" || true
		hook_health_exit 0
		;;
	record)
		customs_emit_event "customs.egress.flagged" \
			"$(_customs_payload '{tool: $t, kinds: $k, hosts: $h, decision: $d}' none)" || true
		hook_health_exit 0
		;;
	flag)
		customs_emit_event "customs.egress.flagged" \
			"$(_customs_payload '{tool: $t, kinds: $k, hosts: $h, decision: $d}' "$MODE")" || true
		REASON=$(customs_reason "$KINDS" "$DECIDE_HOSTS")
		jq -cn --arg d "$MODE" --arg r "$REASON" \
			'{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
		hook_health_exit 0
		;;
	*)
		_customs_fail_open "config"
		;;
esac

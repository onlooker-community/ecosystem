#!/usr/bin/env bash
# Governor PostToolUse hook (matcher: Task).
#
# Records each completed Task call in the JSONL ledger. Validates whether
# the PostToolUse payload includes actual usage counts (Q1 from issue #40).
#
# Hook contract:
#   - Always exits 0. Recording failure must never block the session.
#   - Skips silently when governor.enabled is false.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

_ECOSYSTEM_ROOT="${ONLOOKER_ECOSYSTEM_ROOT:-}"
if [[ -z "$_ECOSYSTEM_ROOT" ]]; then
	_candidate="$(cd "${PLUGIN_ROOT}/../.." 2>/dev/null && pwd)"
	if [[ -f "${_candidate}/scripts/lib/validate-path.sh" ]]; then
		_ECOSYSTEM_ROOT="$_candidate"
	fi
fi

if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/portable-lock.sh"
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/governor-config.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-config.sh"
# shellcheck source=../lib/governor-events.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-events.sh"
# shellcheck source=../lib/governor-estimate.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-estimate.sh"
# shellcheck source=../lib/governor-ledger.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-ledger.sh"

_done() { exit 0; }

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$SESSION_ID" ]] && SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

governor_config_load "$CWD"

if ! governor_config_enabled; then
	_done
fi

# -----------------------------------------------------------------------
# Extract hook fields.
# -----------------------------------------------------------------------
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL_NAME=""
TOOL_INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null) || TOOL_INPUT="{}"
TOOL_RESPONSE=$(printf '%s' "$INPUT" | jq -c '.tool_response // {}' 2>/dev/null) || TOOL_RESPONSE="{}"
DURATION_MS=$(printf '%s' "$INPUT" | jq -r '.duration_ms // 0' 2>/dev/null) || DURATION_MS=0

# Check if actual usage counts are present (Q1 validation).
ACTUAL_INPUT_TOKENS=$(printf '%s' "$TOOL_RESPONSE" \
	| jq -r '.usage.input_tokens // .usage.input_tokens_total // empty' 2>/dev/null) \
	|| ACTUAL_INPUT_TOKENS=""
ACTUAL_OUTPUT_TOKENS=$(printf '%s' "$TOOL_RESPONSE" \
	| jq -r '.usage.output_tokens // .usage.output_tokens_total // empty' 2>/dev/null) \
	|| ACTUAL_OUTPUT_TOKENS=""

# Estimate tokens from the input we sent.
ESTIMATED_TOKENS=$(governor_estimate_tokens "$TOOL_INPUT")
ESTIMATED_COST=$(governor_estimate_cost "$ESTIMATED_TOKENS")
ESTIMATION_METHOD=$(governor_estimate_method)

# Build the completion ledger record.
# estimated_tokens is negated to cancel the reservation written by PreToolUse.
# actual_tokens (when present) complete the two-phase accounting so the running
# total converges to real spend: N_est + (-N_est) + N_act = N_act.
AGENT_TYPE="${TOOL_NAME:-Task}"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || TS="1970-01-01T00:00:00Z"
NEG_ESTIMATED=$(( -ESTIMATED_TOKENS ))

RECORD=$(jq -n \
	--arg ts "$TS" \
	--arg sid "$SESSION_ID" \
	--arg aid "${CLAUDE_SESSION_ID:-unknown}" \
	--arg at "$AGENT_TYPE" \
	--argjson est "$NEG_ESTIMATED" \
	--argjson cost "$ESTIMATED_COST" \
	--argjson dur "$DURATION_MS" \
	'{
		ts: $ts,
		session_id: $sid,
		agent_id: $aid,
		agent_type: $at,
		estimated_tokens: $est,
		cost_usd_estimated: $cost,
		duration_ms: $dur
	}' 2>/dev/null) || RECORD="{}"

# Compute actual total once; used for both the ledger record and the event payload.
ACTUAL_TOTAL=""
if [[ -n "$ACTUAL_INPUT_TOKENS" && -n "$ACTUAL_OUTPUT_TOKENS" ]]; then
	ACTUAL_TOTAL=$(( ACTUAL_INPUT_TOKENS + ACTUAL_OUTPUT_TOKENS ))
	RECORD=$(printf '%s' "$RECORD" | jq \
		--argjson actual "$ACTUAL_TOTAL" \
		'. + {actual_tokens: $actual}' 2>/dev/null) || true
fi

governor_ledger_append "$SESSION_ID" "$RECORD" || true

# Build the governor.call.recorded payload.
CALL_PAYLOAD=$(jq -n \
	--arg sid "$SESSION_ID" \
	--arg aid "${CLAUDE_SESSION_ID:-unknown}" \
	--arg at "$AGENT_TYPE" \
	--argjson est "$ESTIMATED_TOKENS" \
	--argjson cost "$ESTIMATED_COST" \
	--argjson dur "$DURATION_MS" \
	'{
		session_id: $sid,
		agent_id: $aid,
		agent_type: $at,
		estimated_tokens: $est,
		cost_usd_estimated: $cost,
		duration_ms: $dur
	}' 2>/dev/null) || CALL_PAYLOAD="{}"

if [[ -n "$ACTUAL_TOTAL" ]]; then
	ESTIMATION_ERROR=""
	if (( ACTUAL_TOTAL > 0 )); then
		ESTIMATION_ERROR=$(awk \
			"BEGIN { printf \"%.2f\", (($ESTIMATED_TOKENS - $ACTUAL_TOTAL) / $ACTUAL_TOTAL) * 100 }" \
			2>/dev/null) || ESTIMATION_ERROR=""
	fi
	CALL_PAYLOAD=$(printf '%s' "$CALL_PAYLOAD" | jq \
		--argjson actual "$ACTUAL_TOTAL" \
		--arg err "${ESTIMATION_ERROR:-}" \
		'. + {actual_tokens: $actual, tokens_returned_to_pool: 0}
		 + (if $err != "" then {estimation_error_pct: ($err | tonumber)} else {} end)' \
		2>/dev/null) || true
fi

governor_emit_event "governor.call.recorded" "$CALL_PAYLOAD" || true

_done

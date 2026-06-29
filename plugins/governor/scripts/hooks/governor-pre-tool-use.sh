#!/usr/bin/env bash
# Governor PreToolUse hook (matcher: Task).
#
# Gates Task spawns before they exceed the session budget. Uses
# portable-lock.sh for an atomic check-and-reserve so concurrent spawns
# cannot both pass a budget check simultaneously.
#
# Decision logic:
#   - Estimate tokens for the spawn.
#   - Read current consumed tokens from the JSONL ledger.
#   - Allow if (consumed + estimated) <= budget_tokens.
#   - Emit governor.gate.checked with decision and reason.
#   - In "soft" enforcement: always allow, only emit the event.
#   - In "hard" enforcement: block by returning {"decision": "block"} on
#     stdout with exit 0 (Claude Code PreToolUse block protocol).
#
# Hook contract:
#   - Exit 0 always.
#   - To block: write {"decision": "block", "reason": "..."} to stdout.
#   - To allow: write nothing (or {"decision": "allow"}) to stdout.

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
fi

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# portable-lock.sh is vendored into this plugin's lib dir so the ledger's
# atomic appends keep working when governor is installed standalone, where the
# ecosystem repo's top-level scripts/lib/ is absent from the plugin cache.
# shellcheck source=../lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"

# shellcheck source=../lib/governor-config.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-config.sh"
# shellcheck source=../lib/governor-events.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-events.sh"
# shellcheck source=../lib/governor-estimate.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-estimate.sh"
# shellcheck source=../lib/governor-ledger.sh
source "${PLUGIN_ROOT}/scripts/lib/governor-ledger.sh"

_allow() { exit 0; }

_block() {
	local reason="${1:-budget_exceeded}"
	printf '{"decision":"block","reason":"%s"}\n' "$reason"
	exit 0
}

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$SESSION_ID" ]] && SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

governor_config_load "$CWD"

# -----------------------------------------------------------------------
# Read config.
# -----------------------------------------------------------------------
ENFORCEMENT=$(governor_config_enforcement)
TOKENS_BUDGET=$(governor_config_get '.governor.session.tokens_default')
TOKENS_BUDGET="${TOKENS_BUDGET:-100000}"
SAFETY_MARGIN=$(governor_config_get '.governor.estimation.safety_margin')
SAFETY_MARGIN="${SAFETY_MARGIN:-1.3}"
HARD_STOP_MARGIN=$(governor_config_get '.governor.estimation.hard_stop_margin')
HARD_STOP_MARGIN="${HARD_STOP_MARGIN:-1.5}"

# Respect env-var budget overrides set by orchestrating agents.
if [[ -n "${ONLOOKER_SESSION_BUDGET_TOKENS:-}" ]]; then
	TOKENS_BUDGET="$ONLOOKER_SESSION_BUDGET_TOKENS"
fi

TOOL_INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null) || TOOL_INPUT="{}"
AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.tool_name // "Task"' 2>/dev/null) || AGENT_TYPE="Task"

# -----------------------------------------------------------------------
# Estimate tokens for this spawn.
# -----------------------------------------------------------------------
ESTIMATED_TOKENS=$(governor_estimate_tokens "$TOOL_INPUT" "$SAFETY_MARGIN")
ESTIMATED_COST=$(governor_estimate_cost "$ESTIMATED_TOKENS")
ESTIMATION_METHOD=$(governor_estimate_method)

# -----------------------------------------------------------------------
# Atomic check-and-reserve via the ledger lock.
# -----------------------------------------------------------------------
LEDGER_PATH=$(governor_ledger_path "$SESSION_ID")
GATE_LOCK="${LEDGER_PATH}.gate.lock"

DECISION="allow"
REASON=""
TOKENS_CONSUMED=0

if lock_acquire "$GATE_LOCK" 3; then
	TOKENS_CONSUMED=$(governor_ledger_total_tokens "$SESSION_ID")
	PROJECTED=$(( TOKENS_CONSUMED + ESTIMATED_TOKENS ))

	# Hard stop: unconditionally block when projected exceeds budget * hard_stop_margin.
	HARD_STOP_THRESHOLD=$(awk "BEGIN { printf \"%d\", int($TOKENS_BUDGET * $HARD_STOP_MARGIN) }" 2>/dev/null) \
		|| HARD_STOP_THRESHOLD=$(( TOKENS_BUDGET * 2 ))

	if (( PROJECTED > HARD_STOP_THRESHOLD )); then
		DECISION="block"
		REASON="ceiling_exceeded"
	elif (( PROJECTED > TOKENS_BUDGET )); then
		DECISION="block"
		REASON="budget_exceeded"
	fi

	# Write reservation inside the gate lock so concurrent spawns see in-flight cost.
	if [[ "$DECISION" == "allow" ]]; then
		TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || TS="1970-01-01T00:00:00Z"
		RESERVATION=$(jq -n \
			--arg ts "$TS" \
			--arg sid "$SESSION_ID" \
			--arg aid "${CLAUDE_SESSION_ID:-unknown}" \
			--arg at "$AGENT_TYPE" \
			--argjson est "$ESTIMATED_TOKENS" \
			--argjson cost "$ESTIMATED_COST" \
			'{
				ts: $ts,
				session_id: $sid,
				agent_id: $aid,
				agent_type: $at,
				estimated_tokens: $est,
				cost_usd_estimated: $cost,
				record_type: "reservation"
			}' 2>/dev/null) || RESERVATION="{}"
		governor_ledger_write_direct "$LEDGER_PATH" "$RESERVATION" || true
	fi

	lock_release "$GATE_LOCK"
else
	# Could not acquire gate lock — treat as block to be safe in hard mode.
	DECISION="block"
	REASON="lock_timeout"
fi

TOKENS_AVAILABLE=$(( TOKENS_BUDGET - TOKENS_CONSUMED ))
(( TOKENS_AVAILABLE < 0 )) && TOKENS_AVAILABLE=0

# -----------------------------------------------------------------------
# Emit governor.gate.checked.
# -----------------------------------------------------------------------
GATE_PAYLOAD=$(jq -n \
	--arg sid "$SESSION_ID" \
	--arg aid "${CLAUDE_SESSION_ID:-unknown}" \
	--arg at "$AGENT_TYPE" \
	--arg dec "$DECISION" \
	--argjson est "$ESTIMATED_TOKENS" \
	--argjson avail "$TOKENS_AVAILABLE" \
	--arg method "$ESTIMATION_METHOD" \
	--argjson margin "$SAFETY_MARGIN" \
	'{
		session_id: $sid,
		agent_id: $aid,
		agent_type: $at,
		decision: $dec,
		estimated_tokens: $est,
		tokens_available: $avail,
		estimation_method: $method,
		safety_margin: $margin
	}' 2>/dev/null) || GATE_PAYLOAD="{}"

if [[ -n "$REASON" ]]; then
	GATE_PAYLOAD=$(printf '%s' "$GATE_PAYLOAD" \
		| jq --arg r "$REASON" '. + {reason: $r}' 2>/dev/null) \
		|| true
fi

governor_emit_event "governor.gate.checked" "$GATE_PAYLOAD" || true

# -----------------------------------------------------------------------
# Enforce decision.
# -----------------------------------------------------------------------
# ceiling_exceeded always blocks regardless of enforcement mode.
# budget_exceeded and lock_timeout only block in hard enforcement mode.
if [[ "$DECISION" == "block" ]]; then
	if [[ "$REASON" == "ceiling_exceeded" || "$ENFORCEMENT" == "hard" ]]; then
		_block "${REASON:-budget_exceeded}"
	fi
fi

_allow

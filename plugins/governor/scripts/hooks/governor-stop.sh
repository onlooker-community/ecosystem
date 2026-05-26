#!/usr/bin/env bash
# Governor Stop hook.
#
# Fires at session end. Emits governor.session.complete with cumulative
# spend totals from the JSONL ledger.
#
# Hook contract:
#   - Always exits 0. Never blocks Stop.
#   - Skips silently when governor.enabled is false.
#   - Errors from ledger reads are swallowed; emits best-effort totals.

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
# Read session totals from the ledger.
# -----------------------------------------------------------------------
TOTAL_TOKENS=$(governor_ledger_total_tokens "$SESSION_ID")
TOTAL_COST=$(governor_ledger_total_cost "$SESSION_ID")
TOTAL_CALLS=$(governor_ledger_call_count "$SESSION_ID")
LEDGER_POISONED=$(governor_ledger_is_poisoned "$SESSION_ID" && printf 'true' || printf 'false')

TOKENS_BUDGET=$(governor_config_get '.governor.session.tokens_default')
TOKENS_BUDGET="${TOKENS_BUDGET:-100000}"
COST_BUDGET=$(governor_config_get '.governor.session.cost_usd_default')
COST_BUDGET="${COST_BUDGET:-1.0}"

if [[ -n "${ONLOOKER_SESSION_BUDGET_TOKENS:-}" ]]; then
	TOKENS_BUDGET="$ONLOOKER_SESSION_BUDGET_TOKENS"
fi

UNDER_BUDGET="true"
TOTAL_TOKENS_INT=$(printf '%s' "${TOTAL_TOKENS:-0}" | grep -oE '^[0-9]+' || printf '0')
TOKENS_BUDGET_INT=$(printf '%s' "${TOKENS_BUDGET:-0}" | grep -oE '^[0-9]+' || printf '0')
(( TOTAL_TOKENS_INT > TOKENS_BUDGET_INT )) && UNDER_BUDGET="false"

# Also check the cost dimension (float comparison via awk).
if [[ "$UNDER_BUDGET" == "true" ]]; then
	COST_OVER=$(awk "BEGIN { print (${TOTAL_COST:-0} > ${COST_BUDGET:-1.0}) ? 1 : 0 }" 2>/dev/null) || COST_OVER=0
	[[ "$COST_OVER" == "1" ]] && UNDER_BUDGET="false"
fi

SESSION_PAYLOAD=$(jq -n \
	--argjson total_cost "${TOTAL_COST:-0}" \
	--argjson budget_usd "${COST_BUDGET:-1.0}" \
	--argjson under "$( [[ "$UNDER_BUDGET" == "true" ]] && printf 'true' || printf 'false')" \
	--arg sid "$SESSION_ID" \
	--argjson total_tokens "${TOTAL_TOKENS_INT:-0}" \
	--argjson total_calls "${TOTAL_CALLS:-0}" \
	--argjson dur 0 \
	--argjson calls_blocked 0 \
	--argjson calls_warned 0 \
	--argjson poisoned "$( [[ "$LEDGER_POISONED" == "true" ]] && printf 'true' || printf 'false')" \
	'{
		total_cost_usd: $total_cost,
		budget_usd: $budget_usd,
		under_budget: $under,
		session_id: $sid,
		total_tokens: $total_tokens,
		total_api_calls: $total_calls,
		duration_ms: $dur,
		calls_blocked: $calls_blocked,
		calls_warned: $calls_warned,
		ledger_poisoned: $poisoned
	}' 2>/dev/null) || SESSION_PAYLOAD="{}"

governor_emit_event "governor.session.complete" "$SESSION_PAYLOAD" || true

_done

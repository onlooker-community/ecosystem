#!/usr/bin/env bash
# Bursar SessionEnd hook.
#
# Fires when a session ends. Responsibilities:
#   1. Skip silently when bursar.enabled is false.
#   2. Resolve the project key for the ending session (breadcrumb first, then
#      the substrate session-tracker cwd, then the current cwd).
#   3. Read this session's spend from the shared event bus — the latest
#      governor.session.complete for this session_id. When governor is absent
#      the session is still recorded, with cost unknown (governor_present:false).
#   4. Upsert the session's spend into the per-project rollup ledger.
#   5. Emit bursar.session.recorded and drop the breadcrumb.
#
# Hook contract:
#   - Always exits 0. Never blocks session termination.
#   - Errors are written to stderr only; stdout is kept clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# shellcheck source=../lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=../lib/bursar-config.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-config.sh"
# shellcheck source=../lib/bursar-events.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-events.sh"
# shellcheck source=../lib/bursar-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-project-key.sh"
# shellcheck source=../lib/bursar-ledger.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-ledger.sh"

INPUT=$(cat)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

_done() { exit 0; }

[[ -z "$SESSION_ID" ]] && _done

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
SAFE_SID=$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9-' '_')
BREADCRUMB="${ONLOOKER_DIR}/bursar/sessions/${SAFE_SID}.json"
TRACKER="${ONLOOKER_DIR}/session-trackers/${SESSION_ID}"

# -----------------------------------------------------------------------
# Resolve project key + cwd: breadcrumb → substrate tracker → live cwd.
# -----------------------------------------------------------------------
PROJECT_KEY=""
if [[ -f "$BREADCRUMB" ]]; then
	PROJECT_KEY=$(jq -r '.project_key // ""' "$BREADCRUMB" 2>/dev/null) || PROJECT_KEY=""
	[[ -z "$CWD" ]] && CWD=$(jq -r '.cwd // ""' "$BREADCRUMB" 2>/dev/null)
fi
if [[ -z "$CWD" && -f "$TRACKER" ]]; then
	CWD=$(jq -r '.cwd // ""' "$TRACKER" 2>/dev/null) || CWD=""
fi
[[ -z "$CWD" ]] && CWD="$(pwd)"

bursar_config_load "$CWD"
bursar_config_enabled || _done

[[ -z "$PROJECT_KEY" ]] && PROJECT_KEY=$(bursar_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && _done

# -----------------------------------------------------------------------
# Read this session's spend off the shared event bus: the last
# governor.session.complete carries the session's cumulative totals.
# -----------------------------------------------------------------------
LOG="${ONLOOKER_EVENTS_LOG:-${ONLOOKER_DIR}/logs/onlooker-events.jsonl}"
GOV_PRESENT="false"
COST=""
TOKENS=""
CALLS=""

if [[ -f "$LOG" ]]; then
	SPEND=$(grep -F '"governor.session.complete"' "$LOG" 2>/dev/null \
		| jq -c --arg sid "$SESSION_ID" \
			'select(.event_type == "governor.session.complete" and .payload.session_id == $sid) | .payload' \
			2>/dev/null \
		| tail -n 1)
	if [[ -n "$SPEND" ]]; then
		GOV_PRESENT="true"
		COST=$(printf '%s' "$SPEND" | jq -r '.total_cost_usd // empty' 2>/dev/null) || COST=""
		TOKENS=$(printf '%s' "$SPEND" | jq -r '.total_tokens // empty' 2>/dev/null) || TOKENS=""
		CALLS=$(printf '%s' "$SPEND" | jq -r '.total_api_calls // empty' 2>/dev/null) || CALLS=""
	fi
fi

MODEL=""
[[ -f "$TRACKER" ]] && MODEL=$(jq -r '.model // ""' "$TRACKER" 2>/dev/null)

# -----------------------------------------------------------------------
# Build the record and the event payload, attaching spend fields only when
# governor supplied them.
# -----------------------------------------------------------------------
add_fields() {
	# Echoes the input JSON ($1) with cost/tokens/calls/model merged in.
	local base="$1"
	[[ -n "$COST" ]] && base=$(printf '%s' "$base" | jq --argjson v "$COST" '. + {cost_usd: $v}' 2>/dev/null)
	[[ -n "$TOKENS" ]] && base=$(printf '%s' "$base" | jq --argjson v "$TOKENS" '. + {tokens: $v}' 2>/dev/null)
	[[ -n "$CALLS" ]] && base=$(printf '%s' "$base" | jq --argjson v "$CALLS" '. + {api_calls: $v}' 2>/dev/null)
	[[ -n "$MODEL" ]] && base=$(printf '%s' "$base" | jq --arg v "$MODEL" '. + {model: $v}' 2>/dev/null)
	printf '%s' "$base"
}

RECORD=$(jq -n \
	--arg ts "$(bursar_now_iso)" \
	--argjson te "$(bursar_now_epoch)" \
	--arg sid "$SESSION_ID" \
	--arg pk "$PROJECT_KEY" \
	--argjson gp "$GOV_PRESENT" \
	'{ts: $ts, ts_epoch: $te, session_id: $sid, project_key: $pk, governor_present: $gp}' 2>/dev/null)
RECORD=$(add_fields "$RECORD")
[[ -n "$RECORD" ]] && bursar_ledger_record "$PROJECT_KEY" "$RECORD" || true

EV=$(jq -n \
	--arg pk "$PROJECT_KEY" \
	--arg sid "$SESSION_ID" \
	--argjson gp "$GOV_PRESENT" \
	'{project_key: $pk, session_id: $sid, governor_present: $gp}' 2>/dev/null)
EV=$(add_fields "$EV")
[[ -n "$EV" ]] && bursar_emit_event "bursar.session.recorded" "$EV" "$SESSION_ID" || true

rm -f "$BREADCRUMB" 2>/dev/null || true

_done

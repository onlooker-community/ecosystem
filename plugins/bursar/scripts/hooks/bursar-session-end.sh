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

_done() { exit 0; }

# Parse session_id and cwd in a single jq pass (one fork, not two).
{ IFS= read -r SESSION_ID; IFS= read -r CWD; } < <(printf '%s' "$INPUT" | jq -r '.session_id // "", .cwd // ""' 2>/dev/null)

[[ -z "$SESSION_ID" ]] && _done

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"
SAFE_SID=$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9-' '_')
BREADCRUMB="${ONLOOKER_DIR}/bursar/sessions/${SAFE_SID}.json"
TRACKER="${ONLOOKER_DIR}/session-trackers/${SESSION_ID}"

# -----------------------------------------------------------------------
# Resolve project key + cwd: breadcrumb → substrate tracker → live cwd.
# The breadcrumb (dropped at SessionStart) usually carries both, which lets us
# skip the git + shasum project-key derivation entirely in the common case.
# -----------------------------------------------------------------------
PROJECT_KEY=""
if [[ -f "$BREADCRUMB" ]]; then
	{ IFS= read -r PROJECT_KEY; IFS= read -r bc_cwd; } < <(jq -r '.project_key // "", .cwd // ""' "$BREADCRUMB" 2>/dev/null)
	[[ -z "$CWD" ]] && CWD="$bc_cwd"
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

# Reads event-log lines on stdin; emits one TSV line "cost<TAB>tokens<TAB>calls"
# for the latest governor.session.complete matching this session (empty if none).
# grep pre-filters so jq only parses the handful of matching lines, and the
# field extraction happens in the same jq pass that selects the latest match —
# replacing the prior select + three separate jq extractions.
_latest_governor_spend() {
	grep -F '"governor.session.complete"' 2>/dev/null \
		| jq -rs --arg sid "$SESSION_ID" '
			[ .[]
			  | select(.event_type == "governor.session.complete" and .payload.session_id == $sid)
			  | .payload ]
			| if length == 0 then empty
			  else (.[-1] | [(.total_cost_usd // ""), (.total_tokens // ""), (.total_api_calls // "")] | @tsv)
			  end' \
			2>/dev/null
}

if [[ -f "$LOG" ]]; then
	# The matching event was emitted seconds ago (governor's final Stop), so it is
	# almost always near the tail. Scan a recent slice first to keep this hook
	# fast as the global log grows; fall back to the full file only on a miss.
	SPEND=$(tail -n 2000 "$LOG" 2>/dev/null | _latest_governor_spend)
	[[ -z "$SPEND" ]] && SPEND=$(_latest_governor_spend < "$LOG")
	if [[ -n "$SPEND" ]]; then
		GOV_PRESENT="true"
		IFS=$'\t' read -r COST TOKENS CALLS <<<"$SPEND"
	fi
fi

MODEL=""
[[ -f "$TRACKER" ]] && MODEL=$(jq -r '.model // ""' "$TRACKER" 2>/dev/null)

# One date fork yields both the epoch and the RFC3339 stamp (was two).
{ IFS= read -r NOW_EPOCH; IFS= read -r NOW_ISO; } < <(date -u +'%s%n%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
[[ -z "$NOW_EPOCH" ]] && NOW_EPOCH=0

# -----------------------------------------------------------------------
# Build the ledger record AND the (smaller) event payload in a single jq pass.
# Spend fields are passed as strings and coerced with tonumber so an empty value
# is simply omitted — replacing the per-field add_fields() helper that forked a
# jq for every field, twice. The event payload is the record minus the
# ledger-only ts/ts_epoch fields.
# -----------------------------------------------------------------------
{ IFS= read -r RECORD; IFS= read -r EV; } < <(jq -rn \
	--arg ts "$NOW_ISO" \
	--argjson te "$NOW_EPOCH" \
	--arg sid "$SESSION_ID" \
	--arg pk "$PROJECT_KEY" \
	--argjson gp "$GOV_PRESENT" \
	--arg cost "$COST" \
	--arg tokens "$TOKENS" \
	--arg calls "$CALLS" \
	--arg model "$MODEL" \
	'
	( {ts: $ts, ts_epoch: $te, session_id: $sid, project_key: $pk, governor_present: $gp}
	  + (if $cost   != "" then {cost_usd:  ($cost   | tonumber)} else {} end)
	  + (if $tokens != "" then {tokens:    ($tokens | tonumber)} else {} end)
	  + (if $calls  != "" then {api_calls: ($calls  | tonumber)} else {} end)
	  + (if $model  != "" then {model: $model} else {} end)
	) as $record
	| ($record | tojson), ($record | del(.ts, .ts_epoch) | tojson)
	' 2>/dev/null)

# Only claim the session was recorded — and only drop the breadcrumb — once the
# ledger upsert actually succeeds. A failed write (lock timeout, mv failure)
# must keep the breadcrumb so the session→project attribution survives for a
# later attempt rather than being lost behind a false "recorded" event.
if [[ -n "$RECORD" ]] && bursar_ledger_record "$PROJECT_KEY" "$RECORD"; then
	[[ -n "$EV" ]] && bursar_emit_event "bursar.session.recorded" "$EV" "$SESSION_ID" || true

	rm -f "$BREADCRUMB" 2>/dev/null || true
fi

_done

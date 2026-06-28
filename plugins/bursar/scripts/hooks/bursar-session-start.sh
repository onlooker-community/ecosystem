#!/usr/bin/env bash
# Bursar SessionStart hook.
#
# Fires at every session start. Responsibilities:
#   1. Derive the project key from the session cwd and stash a breadcrumb
#      (project_key + cwd) so SessionEnd can attribute spend even though the
#      SessionEnd payload only reliably carries session_id.
#   2. Surface "this project burned $X this week" by summing the per-project
#      ledger over the configured window and emitting it as SessionStart
#      additionalContext.
#   3. Emit bursar.rollup.surfaced (or bursar.rollup.skipped) for audit.
#
# Hook contract:
#   - Always exits 0. Never blocks SessionStart.
#   - Only the additionalContext JSON is written to stdout; errors go to stderr.

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

bursar_config_load "$CWD"

[[ -z "$CWD" ]] && CWD="$(pwd)"
PROJECT_KEY=$(bursar_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && _done   # not a recognizable project — nothing to attribute

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"

# -----------------------------------------------------------------------
# Breadcrumb: lets SessionEnd resolve the project key without re-deriving
# from a cwd it may not have.
# -----------------------------------------------------------------------
if [[ -n "$SESSION_ID" ]]; then
	BREADCRUMB_DIR="${ONLOOKER_DIR}/bursar/sessions"
	mkdir -p "$BREADCRUMB_DIR" 2>/dev/null || true
	safe_sid=$(printf '%s' "$SESSION_ID" | tr -c 'a-zA-Z0-9-' '_')
	jq -n --arg pk "$PROJECT_KEY" --arg cwd "$CWD" --arg ts "$(bursar_now_iso)" \
		'{project_key: $pk, cwd: $cwd, started_at: $ts}' \
		>"${BREADCRUMB_DIR}/${safe_sid}.json" 2>/dev/null || true
fi

# -----------------------------------------------------------------------
# Surface the rolling total (opt-out via bursar.surface_at_session_start).
# -----------------------------------------------------------------------
bursar_config_surface_enabled || _done

WINDOW=$(bursar_config_window)
WEEK_START=$(bursar_config_week_start)
CUTOFF=$(bursar_window_cutoff_epoch "$WINDOW" "$WEEK_START")
TOTALS=$(bursar_window_totals "$PROJECT_KEY" "$CUTOFF")

SESSION_COUNT=$(printf '%s' "$TOTALS" | jq -r '.session_count // 0' 2>/dev/null) || SESSION_COUNT=0
TOTAL_COST=$(printf '%s' "$TOTALS" | jq -r '.total_cost_usd // 0' 2>/dev/null) || TOTAL_COST=0
TOTAL_TOKENS=$(printf '%s' "$TOTALS" | jq -r '.total_tokens // 0' 2>/dev/null) || TOTAL_TOKENS=0
SESSIONS_WITH_COST=$(printf '%s' "$TOTALS" | jq -r '.sessions_with_cost // 0' 2>/dev/null) || SESSIONS_WITH_COST=0

# Nothing recorded yet in the window.
if [[ "${SESSION_COUNT:-0}" -eq 0 ]]; then
	skipped=$(jq -n --arg pk "$PROJECT_KEY" '{reason: "no_data", project_key: $pk}' 2>/dev/null) || skipped='{"reason":"no_data"}'
	bursar_emit_event "bursar.rollup.skipped" "$skipped" "$SESSION_ID" || true
	_done
fi

# Below the noise threshold — record nothing on screen.
MIN_COST=$(bursar_config_min_cost)
if [[ "$(awk -v c="$TOTAL_COST" -v m="$MIN_COST" 'BEGIN { print (c < m) ? 1 : 0 }')" == "1" ]]; then
	_done
fi

WINDOW_LABEL="in the last 7 days"
[[ "$WINDOW" == "calendar_week" ]] && WINDOW_LABEL="this week"
COST_FMT=$(awk -v c="$TOTAL_COST" 'BEGIN { printf "%.2f", c }')
TOKENS_FMT=$(bursar_fmt_tokens "$TOTAL_TOKENS")
SESS_NOUN=$([[ "${SESSION_COUNT:-0}" -eq 1 ]] && printf 'session' || printf 'sessions')

# Key the "enable governor" prompt on cost *coverage*, not on the dollar total:
# governor can legitimately report $0.00 for a window, and that should still
# render as a tracked total rather than a nudge to enable governor.
if [[ "${SESSIONS_WITH_COST:-0}" -eq 0 ]]; then
	MSG="Bursar: ${SESSION_COUNT} ${SESS_NOUN} in this project ${WINDOW_LABEL}. Enable governor for \$ cost tracking."
elif [[ "${SESSIONS_WITH_COST:-0}" -lt "${SESSION_COUNT:-0}" ]]; then
	MSG="Bursar: this project burned \$${COST_FMT} across ${SESSIONS_WITH_COST} of ${SESSION_COUNT} sessions ${WINDOW_LABEL} (~${TOKENS_FMT} tokens); enable governor in the rest for full cost tracking."
else
	MSG="Bursar: this project burned \$${COST_FMT} across ${SESSION_COUNT} ${SESS_NOUN} ${WINDOW_LABEL} (~${TOKENS_FMT} tokens)."
fi

WINDOW_START_ISO=$(bursar_epoch_to_iso "$CUTOFF")
surfaced=$(jq -n \
	--arg pk "$PROJECT_KEY" \
	--arg w "$WINDOW" \
	--argjson cost "$TOTAL_COST" \
	--argjson sc "$SESSION_COUNT" \
	--argjson tok "$TOTAL_TOKENS" \
	--argjson swc "$SESSIONS_WITH_COST" \
	--arg ws "$WINDOW_START_ISO" \
	'{
		project_key: $pk,
		window: $w,
		total_cost_usd: $cost,
		session_count: $sc,
		total_tokens: $tok,
		sessions_with_cost: $swc
	}
	+ (if $ws != "" then {window_start: $ws} else {} end)' 2>/dev/null) || surfaced=""
[[ -n "$surfaced" ]] && bursar_emit_event "bursar.rollup.surfaced" "$surfaced" "$SESSION_ID" || true

jq -cn --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'

_done

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
#   3. Emit bursar.rollup.surfaced (or bursar.rollup.skipped) for audit,
#      detached so SessionStart does not wait on node.
#   4. Launch bursar-replay.sh detached, which records the sessions whose
#      SessionEnd never did and so left their breadcrumbs behind (ONL-34).
#
# Hook contract:
#   - Always exits 0. Never blocks SessionStart.
#   - Only the additionalContext JSON is written to stdout; errors go to stderr.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "bursar-session-start"

# shellcheck source=../lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=../lib/bursar-config.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-config.sh"
# shellcheck source=../lib/bursar-events.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-events.sh"
# shellcheck source=../lib/onlooker-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
# shellcheck source=../lib/bursar-ledger.sh
source "${PLUGIN_ROOT}/scripts/lib/bursar-ledger.sh"

INPUT=$(cat)
hook_health_context "$INPUT"
SESSION_ID="$HOOK_INPUT_SESSION_ID"
CWD="$HOOK_INPUT_CWD"

_done() { hook_health_exit 0; }

# Every SessionStart hook starts at the same moment, so each process this one
# spawns costs about 1.7x its isolated time (ONL-292), and this hook sets the
# SessionStart span (ONL-296). Count process starts before adding one.

# _emit <type> <payload> — detached, following archivist-mine and the tribunal
# nudge: output discarded, stdin closed, fd 3 closed (or a bats run waits on it
# through that fd), disowned so SessionStart does not wait on node. Nothing
# reads these events before the hook exits.
_emit() {
	bursar_emit_event "$1" "$2" "$SESSION_ID" </dev/null >/dev/null 2>&1 3>&- &
	disown 2>/dev/null || true
}

bursar_config_load "$CWD"

[[ -z "$CWD" ]] && CWD="$(pwd)"
onlooker_project_resolve "$CWD"
PROJECT_KEY="$ONLOOKER_PROJECT_KEY"
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
	jq -n --arg sid "$SESSION_ID" --arg pk "$PROJECT_KEY" --arg cwd "$CWD" \
		'{session_id: $sid, project_key: $pk, cwd: $cwd, started_at: (now | floor | todate)}' \
		>"${BREADCRUMB_DIR}/${safe_sid}.json" 2>/dev/null || true
fi

# -----------------------------------------------------------------------
# Replay stranded breadcrumbs. Detached, so a backlog of hundreds costs this
# hook nothing; setsid keeps the session's SIGHUP from killing it, with nohup
# alone on macOS, where setsid needs coreutils. The replay locks against a
# concurrent copy and is a no-op when no breadcrumb is old enough.
# -----------------------------------------------------------------------
REPLAY="${PLUGIN_ROOT}/scripts/bursar-replay.sh"
if [[ -x "$REPLAY" ]]; then
	export ONLOOKER_DIR
	if command -v setsid >/dev/null 2>&1; then
		nohup setsid "$REPLAY" </dev/null >/dev/null 2>&1 &
	else
		nohup "$REPLAY" </dev/null >/dev/null 2>&1 &
	fi
	disown 2>/dev/null || true
fi

# -----------------------------------------------------------------------
# Surface the rolling total (opt-out via bursar.surface_at_session_start).
# -----------------------------------------------------------------------
bursar_config_surface_enabled || _done

WINDOW=$(bursar_config_window)
WEEK_START=$(bursar_config_week_start)
CUTOFF=$(bursar_window_cutoff_epoch "$WINDOW" "$WEEK_START")
TOTALS=$(bursar_window_totals "$PROJECT_KEY" "$CUTOFF")

# One jq for the four totals and the surfaced payload: line 1 is the totals,
# tab-separated; line 2 is the payload, built here while the numbers are still
# JSON. A failed parse leaves SESSION_COUNT empty, which reads as no data.
SESSION_COUNT="" TOTAL_COST=0 TOTAL_TOKENS=0 SESSIONS_WITH_COST=0 surfaced=""
{
	IFS=$'\t' read -r SESSION_COUNT TOTAL_COST TOTAL_TOKENS SESSIONS_WITH_COST
	IFS= read -r surfaced
} < <(printf '%s' "$TOTALS" | jq -r --arg pk "$PROJECT_KEY" --arg w "$WINDOW" --argjson c "${CUTOFF:-0}" '
	(.session_count // 0) as $sc | (.total_cost_usd // 0) as $cost
	| (.total_tokens // 0) as $tok | (.sessions_with_cost // 0) as $swc
	| ([$sc, $cost, $tok, $swc] | @tsv),
	({project_key: $pk, window: $w, total_cost_usd: $cost, session_count: $sc,
		total_tokens: $tok, sessions_with_cost: $swc, window_start: ($c | todate)} | tojson)
' 2>/dev/null)

# Nothing recorded yet in the window. The project key is 12 hex characters
# (onlooker-project-key.sh), so printf needs no JSON escaping here.
if [[ "${SESSION_COUNT:-0}" -eq 0 ]]; then
	_emit "bursar.rollup.skipped" "$(printf '{"reason":"no_data","project_key":"%s"}' "$PROJECT_KEY")"
	_done
fi

BELOW_MIN=0 COST_FMT="" TOKENS_FMT=""
IFS=$'\t' read -r BELOW_MIN COST_FMT TOKENS_FMT \
	< <(bursar_fmt_surface "$TOTAL_COST" "$TOTAL_TOKENS" "$(bursar_config_min_cost)")

# Below the noise threshold — record nothing on screen.
[[ "$BELOW_MIN" == "1" ]] && _done

WINDOW_LABEL="in the last 7 days"
[[ "$WINDOW" == "calendar_week" ]] && WINDOW_LABEL="this week"
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

[[ -n "$surfaced" ]] && _emit "bursar.rollup.surfaced" "$surfaced"

# MSG is built only from fixed text, numbers and the window label, so it holds
# nothing JSON would escape and printf can write it without jq.
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$MSG"

_done

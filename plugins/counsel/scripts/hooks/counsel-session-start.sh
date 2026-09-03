#!/usr/bin/env bash
# Counsel SessionStart hook — weekly improvement brief injection.
#
# Fires at session start. If the last brief for this project is older than
# synthesis_interval_days (default: 7), runs a Haiku synthesis pass over the
# full event log and injects the resulting brief as additionalContext.
#
# Skip conditions (all silent):
#   - no project key (non-git directory)
#   - brief is still fresh
#   - fewer than min_events events in the lookback window
#
# Hook contract:
#   - Always exits 0. Never blocks session start.
#   - Emits hookSpecificOutput JSON on stdout (even when context is empty).
#   - Errors are written to stderr only.

set -uo pipefail

# Recursion guard — must be first, above hook_health_register, so a nested
# invocation is not measured as a real hook run (ecosystem-449.23).
#
# counsel reaches claude through counsel-synthesize.sh. The nested `claude -p`
# is a real session, so it fires SessionStart and re-enters this hook.
[[ "${COUNSEL_NESTED:-}" == "1" ]] && exit 0
export COUNSEL_NESTED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "counsel-session-start"

# shellcheck source=../lib/counsel-config.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-config.sh"
# shellcheck source=../lib/counsel-events.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-events.sh"
# shellcheck source=../lib/counsel-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-project-key.sh"
# shellcheck source=../lib/counsel-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-ulid.sh"
# shellcheck source=../lib/counsel-reader.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-reader.sh"
# shellcheck source=../lib/counsel-synthesize.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-synthesize.sh"
# shellcheck source=../lib/counsel-brief.sh
source "${PLUGIN_ROOT}/scripts/lib/counsel-brief.sh"

_emit() {
	local context="${1:-}"
	jq -cn --arg ctx "$context" '
		{
			hookSpecificOutput: {
				hookEventName: "SessionStart",
				additionalContext: $ctx
			}
		}
	'
}

INPUT=$(cat)
hook_health_context "$INPUT"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

export _HOOK_SESSION_ID="$SESSION_ID"

REPO_ROOT=$(counsel_project_repo_root "$CWD")
counsel_config_load "$REPO_ROOT"

PROJECT_KEY=$(counsel_project_key "$CWD")
if [[ -z "$PROJECT_KEY" ]]; then
	_emit ""
	exit 0
fi

# Refresh detached when the brief has aged out. Synthesis is never run inline:
# the evaluator ships timeout 90 and this is SessionStart, so an inline call
# blocked the user for up to a minute and a half (ecosystem-449.19). The
# interval gate bounds how often that happened, not how long it took.
#
# Nothing waits on the spawn, and this session injects whatever brief already
# exists. The refreshed one lands at the next session start — a weekly digest
# does not care about a one-session delay.
INTERVAL_DAYS=$(counsel_config_get '.counsel.synthesis_interval_days')
[[ -z "$INTERVAL_DAYS" || "$INTERVAL_DAYS" == "null" ]] && INTERVAL_DAYS="7"

if counsel_brief_is_stale "$PROJECT_KEY" "$INTERVAL_DAYS"; then
	REFRESH="${PLUGIN_ROOT}/scripts/counsel-refresh.sh"
	if [[ -x "$REFRESH" ]]; then
		# setsid detaches from the controlling terminal so closing the session
		# does not SIGHUP the synthesis mid-flight; nohup alone on macOS, where
		# setsid needs coreutils. Same shape as cartographer's ADR-001.
		if command -v setsid >/dev/null 2>&1; then
			nohup setsid "$REFRESH" "$SESSION_ID" "$CWD" "$PROJECT_KEY" >/dev/null 2>&1 &
		else
			nohup "$REFRESH" "$SESSION_ID" "$CWD" "$PROJECT_KEY" >/dev/null 2>&1 &
		fi
		disown 2>/dev/null || true
	fi
fi

OUTPUT_PATH=$(counsel_brief_latest "$PROJECT_KEY" 2>/dev/null) || OUTPUT_PATH=""

if [[ -z "$OUTPUT_PATH" || ! -f "$OUTPUT_PATH" ]]; then
	_emit ""
	exit 0
fi

# Already shown. A weekly brief injected every session until it ages out would
# reach the user seven times.
if counsel_brief_was_injected "$PROJECT_KEY" "$OUTPUT_PATH"; then
	_emit ""
	exit 0
fi

# Load the brief content and apply the configured char budget.
BRIEF_MAX_CHARS=$(counsel_config_get '.counsel.output.brief_max_chars')
[[ -z "$BRIEF_MAX_CHARS" || "$BRIEF_MAX_CHARS" == "null" ]] && BRIEF_MAX_CHARS="3000"

BRIEF_CONTENT=$(head -c "$BRIEF_MAX_CHARS" "$OUTPUT_PATH" 2>/dev/null) || BRIEF_CONTENT=""

if [[ -z "$BRIEF_CONTENT" ]]; then
	_emit ""
	exit 0
fi

CONTEXT="Counsel — weekly improvement brief (auto-generated from your onlooker event log):

${BRIEF_CONTENT}

(Counsel injected this brief for project key ${PROJECT_KEY}.)"

counsel_brief_mark_injected "$PROJECT_KEY" "$OUTPUT_PATH" || true

_emit "$CONTEXT"
exit 0

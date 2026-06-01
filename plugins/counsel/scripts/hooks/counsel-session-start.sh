#!/usr/bin/env bash
# Counsel SessionStart hook — weekly improvement brief injection.
#
# Fires at session start. If the last brief for this project is older than
# synthesis_interval_days (default: 7), runs a Haiku synthesis pass over the
# full event log and injects the resulting brief as additionalContext.
#
# Skip conditions (all silent):
#   - counsel.enabled is false
#   - no project key (non-git directory)
#   - brief is still fresh
#   - fewer than min_events events in the lookback window
#
# Hook contract:
#   - Always exits 0. Never blocks session start.
#   - Emits hookSpecificOutput JSON on stdout (even when context is empty).
#   - Errors are written to stderr only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

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
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""

export _HOOK_SESSION_ID="$SESSION_ID"

REPO_ROOT=$(counsel_project_repo_root "$CWD")
counsel_config_load "$REPO_ROOT"

if ! counsel_config_enabled; then
	_emit ""
	exit 0
fi

PROJECT_KEY=$(counsel_project_key "$CWD")
if [[ -z "$PROJECT_KEY" ]]; then
	_emit ""
	exit 0
fi

_generate_rc=0
OUTPUT_PATH=$(counsel_generate_brief "$SESSION_ID" "$CWD") || _generate_rc=$?

if [[ $_generate_rc -ne 0 ]]; then
	# rc=2 means stale check passed (brief is fresh) or too few events — silent skip.
	[[ $_generate_rc -ne 2 ]] && printf 'counsel-session-start: brief generation failed for session %s\n' "$SESSION_ID" >&2
	_emit ""
	exit 0
fi

if [[ -z "$OUTPUT_PATH" || ! -f "$OUTPUT_PATH" ]]; then
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

(Counsel injected this brief for project key ${PROJECT_KEY}. Set counsel.enabled=false to disable.)"

_emit "$CONTEXT"
exit 0

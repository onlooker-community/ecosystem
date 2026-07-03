#!/usr/bin/env bash
# Librarian SessionStart surfacer.
#
# Counts pending proposals in the project's queue and injects a one-line
# `additionalContext` pointer if any exist. The full proposal bodies live
# in ~/.onlooker/librarian/<project-key>/proposals/ and are reviewed via
# the /librarian review skill rather than inlined here — SessionStart
# context is precious, and a queue of 20 distilled-but-unreviewed memories
# isn't where it should go.
#
# Hook contract:
#   - Always exits 0. Never blocks session start.
#   - Emits valid hookSpecificOutput JSON, even when nothing to say.
#   - No-ops when there is no project key (no git context).

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

# shellcheck source=../lib/librarian-config.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
# shellcheck source=../lib/librarian-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
# shellcheck source=../lib/librarian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"

# Emit hookSpecificOutput with the given additionalContext string. An
# empty string is fine — the harness sees "nothing to say".
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

INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
[[ -z "$CWD" ]] && CWD="$(pwd)"

REPO_ROOT=$(librarian_project_repo_root "$CWD")
librarian_config_load "$REPO_ROOT"

PROJECT_KEY=$(librarian_project_key "$CWD")
if [[ -z "$PROJECT_KEY" ]]; then
	_emit ""
	exit 0
fi

SKIP_WHEN_ZERO=$(librarian_config_get '.librarian.surfacer.skip_inject_when_zero')
[[ -z "$SKIP_WHEN_ZERO" || "$SKIP_WHEN_ZERO" == "null" ]] && SKIP_WHEN_ZERO="true"

MAX_PENDING=$(librarian_config_get '.librarian.surfacer.max_pending_for_inject')
[[ -z "$MAX_PENDING" || "$MAX_PENDING" == "null" ]] && MAX_PENDING=20

PENDING=$(librarian_storage_count_pending "$PROJECT_KEY")
[[ -z "$PENDING" || "$PENDING" == "null" ]] && PENDING=0

if [[ "$PENDING" -eq 0 && "$SKIP_WHEN_ZERO" == "true" ]]; then
	_emit ""
	exit 0
fi

# Cap the surfaced number so a runaway queue doesn't make the pointer
# itself look alarming. Users still see the truthful count in
# /librarian review.
if [[ "$PENDING" -gt "$MAX_PENDING" ]]; then
	DISPLAY_COUNT="${MAX_PENDING}+"
else
	DISPLAY_COUNT="$PENDING"
fi

NOUN="proposals"
[[ "$PENDING" -eq 1 ]] && NOUN="proposal"

CONTEXT=$(printf 'Librarian has %s pending memory promotion %s. Review with `/librarian review`.' \
	"$DISPLAY_COUNT" "$NOUN")

_emit "$CONTEXT"
exit 0

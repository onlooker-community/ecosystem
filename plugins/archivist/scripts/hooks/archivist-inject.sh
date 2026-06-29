#!/usr/bin/env bash
# Archivist SessionStart injection hook.
#
# Triggered by SessionStart (matcher: *). Loads ranked artifacts for the
# current project key and emits them as invisible `additionalContext` in the
# hook output, within configured budgets.
#
# Ranking: pinned items first (in their pinned order), then everything else by
# updated_at descending. Items are dropped from the bottom of the list once
# either max_items or max_chars is exhausted.
#
# Hook contract:
#   - Always exits 0. Never blocks session start.
#   - Emits valid hookSpecificOutput JSON, even if there's nothing to inject.
#   - Skips work if there are no stored artifacts for the current project.

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

# shellcheck source=../lib/archivist-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-project-key.sh"
# shellcheck source=../lib/archivist-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-storage.sh"
# shellcheck source=../lib/archivist-config.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-config.sh"

# Emit a hookSpecificOutput JSON object with the given additionalContext string.
# Empty string is fine — it just means "nothing to add".
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

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null) || SOURCE="startup"

REPO_ROOT=$(archivist_project_repo_root "$CWD")
PROJECT_KEY=$(archivist_project_key "$CWD")

archivist_config_load "$REPO_ROOT"

if [[ -z "$PROJECT_KEY" ]]; then
	_emit ""
	exit 0
fi

MAX_ITEMS=$(archivist_config_get '.archivist.injection.max_items')
[[ -z "$MAX_ITEMS" || "$MAX_ITEMS" == "null" ]] && MAX_ITEMS=8

MAX_CHARS=$(archivist_config_get '.archivist.injection.max_chars')
[[ -z "$MAX_CHARS" || "$MAX_CHARS" == "null" ]] && MAX_CHARS=2400

INCLUDE_DEAD_ENDS=$(archivist_config_get '.archivist.injection.include_dead_ends')
INCLUDE_OPEN_QUESTIONS=$(archivist_config_get '.archivist.injection.include_open_questions')

RANKED=$(archivist_storage_load_ranked "$PROJECT_KEY")
TOTAL_ITEMS=$(printf '%s' "$RANKED" | jq 'length' 2>/dev/null) || TOTAL_ITEMS=0

if [[ "$TOTAL_ITEMS" -eq 0 ]]; then
	_emit ""
	exit 0
fi

# Filter out kinds the user disabled.
if [[ "$INCLUDE_DEAD_ENDS" != "true" ]]; then
	RANKED=$(printf '%s' "$RANKED" | jq 'map(select(.kind != "dead_ends"))')
fi
if [[ "$INCLUDE_OPEN_QUESTIONS" != "true" ]]; then
	RANKED=$(printf '%s' "$RANKED" | jq 'map(select(.kind != "open_questions"))')
fi

# Build the rendered context one item at a time, respecting both budgets.
HEADER="Archivist — carried over from prior sessions in this repo (kind | summary):"
RENDERED="$HEADER"
RUNNING_CHARS=${#HEADER}
EMITTED=0

COUNT=$(printf '%s' "$RANKED" | jq 'length')
for ((i = 0; i < COUNT; i++)); do
	[[ "$EMITTED" -ge "$MAX_ITEMS" ]] && break

	ITEM=$(printf '%s' "$RANKED" | jq ".[$i]")
	KIND=$(printf '%s' "$ITEM" | jq -r '.kind // ""')
	SUMMARY=$(printf '%s' "$ITEM" | jq -r '.summary // ""')
	DETAIL=$(printf '%s' "$ITEM" | jq -r '.detail // ""')
	PINNED=$(printf '%s' "$ITEM" | jq -r '.pinned // false')
	FILES=$(printf '%s' "$ITEM" | jq -r '(.files // []) | join(", ")')

	[[ -z "$SUMMARY" ]] && continue

	# Map directory-style kinds to human-readable labels.
	LABEL="$KIND"
	case "$KIND" in
		decisions) LABEL="decision" ;;
		dead_ends) LABEL="dead-end" ;;
		open_questions) LABEL="open-question" ;;
	esac

	LINE=""
	if [[ "$PINNED" == "true" ]]; then
		LINE="- [pinned ${LABEL}] ${SUMMARY}"
	else
		LINE="- [${LABEL}] ${SUMMARY}"
	fi
	if [[ -n "$DETAIL" && "$DETAIL" != "null" ]]; then
		LINE="${LINE}"$'\n'"  ${DETAIL}"
	fi
	if [[ -n "$FILES" ]]; then
		LINE="${LINE}"$'\n'"  files: ${FILES}"
	fi

	LINE_LEN=$((${#LINE} + 1))
	if (( RUNNING_CHARS + LINE_LEN > MAX_CHARS )); then
		break
	fi

	RENDERED="${RENDERED}"$'\n'"${LINE}"
	RUNNING_CHARS=$((RUNNING_CHARS + LINE_LEN))
	EMITTED=$((EMITTED + 1))
done

if [[ "$EMITTED" -eq 0 ]]; then
	_emit ""
	exit 0
fi

# Trailer with provenance + how to disable (helps future-you debug).
RENDERED="${RENDERED}"$'\n\n'"(Archivist injected ${EMITTED}/${TOTAL_ITEMS} items for project key ${PROJECT_KEY}. Source: ${SOURCE}.)"

_emit "$RENDERED"
exit 0

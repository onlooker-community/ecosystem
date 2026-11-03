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

# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "archivist-inject"

# Ecosystem substrate (validate-path.sh) lives in the sibling ecosystem plugin.
# Resolution is shared rather than repeated: fourteen hooks each carried a
# byte-identical copy of this lookup, and it was wrong the same two ways in all
# fourteen (ecosystem-449.36, ecosystem-449.35). Fixing it fourteen times is how
# it stayed broken. See scripts/lib/substrate-resolve.sh.
# shellcheck source=../lib/substrate-resolve.sh
source "${PLUGIN_ROOT}/scripts/lib/substrate-resolve.sh"
_ECOSYSTEM_ROOT=$(onlooker_resolve_substrate "$PLUGIN_ROOT")

if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
fi

# shellcheck source=../lib/onlooker-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/onlooker-project-key.sh"
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
hook_health_context "$INPUT"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // "startup"' 2>/dev/null) || SOURCE="startup"

onlooker_project_resolve "$CWD"
PROJECT_KEY="$ONLOOKER_PROJECT_KEY"

archivist_config_load "$CWD"

if [[ -z "$PROJECT_KEY" ]]; then
	_emit ""
	hook_health_exit 0
fi

MAX_ITEMS=$(archivist_config_int '.archivist.injection.max_items' 8)

MAX_CHARS=$(archivist_config_int '.archivist.injection.max_chars' 2400)

INCLUDE_DEAD_ENDS=$(archivist_config_get '.archivist.injection.include_dead_ends')
INCLUDE_OPEN_QUESTIONS=$(archivist_config_get '.archivist.injection.include_open_questions')

# The whole render is one jq over the ranked list. It used to run several jq
# calls per rendered item, each re-parsing every artifact the project has:
# ~780ms for 8 items at 1,221 artifacts (ONL-114). It runs inside the jq that
# reads the artifacts, so the corpus is parsed once. The budgets count
# characters, as ${#LINE} did under the UTF-8 locale sessions run in.
OUTPUT=$(archivist_storage_load_ranked "$PROJECT_KEY" "$(cat <<'JQ'
	def text: if . == null or . == false then "" elif type == "string" then . else tojson end;

	def kind_label:
		if . == "decisions" then "decision"
		elif . == "dead_ends" then "dead-end"
		elif . == "open_questions" then "open-question"
		else . end;
	# null when the item has no summary, which skips it without counting.
	def line:
		((.summary // "") | text) as $summary
		| if $summary == "" then null else
			((.detail // "") | text) as $detail
			| ((try ((.files // []) | join(", ")) catch "") // "") as $files
			| (if .pinned == true then "- [pinned \((.kind // "" | text) | kind_label)] " else "- [\((.kind // "" | text) | kind_label)] " end)
				+ $summary
				+ (if $detail != "" and $detail != "null" then "\n  " + $detail else "" end)
				+ (if $files != "" then "\n  files: " + $files else "" end)
		end;

	"Archivist — carried over from prior sessions in this repo (kind | summary):" as $header
	| length as $total
	| map(select(
		($include_dead_ends == "true" or .kind != "dead_ends")
		and ($include_open_questions == "true" or .kind != "open_questions")))
	| reduce .[] as $item ({text: $header, chars: ($header | length), n: 0, done: false};
		if .done then .
		elif .n >= $max_items then .done = true
		else ($item | line) as $line
			| if $line == null then .
			elif .chars + ($line | length) + 1 > $max_chars then .done = true
			else .text += "\n" + $line | .chars += ($line | length) + 1 | .n += 1
			end
		end)
	| {
		hookSpecificOutput: {
			hookEventName: "SessionStart",
			additionalContext: (if .n == 0 then "" else
				.text + "\n\n(Archivist injected \(.n)/\($total) items for project key \($project_key). Source: \($source).)"
			end)
		}
	}
	| tojson
JQ
)" -r \
	--argjson max_items "$MAX_ITEMS" \
	--argjson max_chars "$MAX_CHARS" \
	--arg include_dead_ends "$INCLUDE_DEAD_ENDS" \
	--arg include_open_questions "$INCLUDE_OPEN_QUESTIONS" \
	--arg project_key "$PROJECT_KEY" \
	--arg source "$SOURCE" 2>/dev/null) || OUTPUT=""

if [[ -z "$OUTPUT" ]]; then
	_emit ""
	hook_health_exit 0
fi

printf '%s\n' "$OUTPUT"
hook_health_exit 0

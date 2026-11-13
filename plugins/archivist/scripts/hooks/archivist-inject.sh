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
#
# The rendered list is cached per project in .inject-cache. Rendering reads
# every artifact the project has to show at most max_items of them: ~60ms of jq
# at 1,345 artifacts, about 2.4x that under SessionStart contention (ONL-260).
# The cache answers while it is strictly newer than each kind directory,
# pinned.json and this script. Every writer creates a file per artifact, so a
# write moves its directory's mtime; a hand edit made in place does not, and is
# not seen until the next artifact is written or a pin changes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../lib/hook-health.sh
source "${PLUGIN_ROOT}/scripts/lib/hook-health.sh"
hook_health_register "archivist-inject"

# No ecosystem substrate: this hook calls no validate_* and emits no events, and
# resolving and sourcing validate-path.sh cost a glob, a jq and a dirname on
# every SessionStart (ONL-260).

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

# Emit a rendered list: <count> <total> <body>, where body is the list already
# escaped for a JSON string. The footer is joined on here so one cached body
# answers every source. A source outside [A-Za-z0-9_-] goes through jq.
_emit_rendered() {
	local n="$1" total="$2" body="$3"
	if [[ "$n" == "0" ]]; then
		_emit ""
		return 0
	fi
	local footer="(Archivist injected ${n}/${total} items for project key ${PROJECT_KEY}. Source: ${SOURCE}.)"
	if [[ "$SOURCE" =~ ^[A-Za-z0-9_-]*$ ]]; then
		printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s\\n\\n%s"}}\n' "$body" "$footer"
	else
		jq -cn --argjson body "\"${body}\"" --arg footer "$footer" \
			'{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ($body + "\n\n" + $footer)}}'
	fi
}

# 0 when the cache may answer: strictly newer than everything its body was
# rendered from. A change in the same second is a miss, as bash 3.2 compares
# whole seconds.
_cache_fresh() {
	local p
	[[ -f "$CACHE_FILE" && "$CACHE_FILE" -nt "${BASH_SOURCE[0]}" ]] || return 1
	for p in decisions dead_ends open_questions pinned.json; do
		[[ -e "${PROJECT_DIR}/${p}" && ! "$CACHE_FILE" -nt "${PROJECT_DIR}/${p}" ]] && return 1
	done
	return 0
}

INPUT=$(cat)
hook_health_context "$INPUT"
CWD="$HOOK_INPUT_CWD"
SOURCE="${HOOK_INPUT_SOURCE:-startup}"

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

PROJECT_DIR=$(archivist_project_dir "$PROJECT_KEY")
CACHE_FILE="${PROJECT_DIR}/.inject-cache"

# What the body was rendered under. Which paths exist is part of it, since a
# kind directory that appears with an old mtime would otherwise pass as fresh.
# So is this script's own path: each release installs to its own directory.
CACHE_KEY="v1|${BASH_SOURCE[0]}|${MAX_ITEMS}|${MAX_CHARS}|${INCLUDE_DEAD_ENDS}|${INCLUDE_OPEN_QUESTIONS}|"
for _p in decisions dead_ends open_questions pinned.json; do
	if [[ -e "${PROJECT_DIR}/${_p}" ]]; then CACHE_KEY+="1"; else CACHE_KEY+="0"; fi
done

if _cache_fresh; then
	_key="" _n="" _total="" _body=""
	{ IFS= read -r _key; IFS= read -r _n; IFS= read -r _total; IFS= read -r _body; } <"$CACHE_FILE" 2>/dev/null
	if [[ "$_key" == "$CACHE_KEY" && "$_n" =~ ^[0-9]+$ && "$_total" =~ ^[0-9]+$ ]]; then
		_emit_rendered "$_n" "$_total" "$_body"
		hook_health_exit 0
	fi
fi

# Stamp the cache with the time this read began, not the time it ends: an
# artifact written mid-read is then newer than the cache that missed it. No
# stamp, as in a store this hook cannot write to, means no cache.
MARK="${CACHE_FILE}.$$"
: >"$MARK" 2>/dev/null || MARK=""

# The whole render is one jq over the ranked list. It used to run several jq
# calls per rendered item, each re-parsing every artifact the project has:
# ~780ms for 8 items at 1,221 artifacts (ONL-114). It runs inside the jq that
# reads the artifacts, so the corpus is parsed once. The budgets count
# characters, as ${#LINE} did under the UTF-8 locale sessions run in.
#
# It prints three lines: the count injected, the total, and the body escaped
# for a JSON string, which is what the cache stores.
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
	| "\(.n)\n\($total)\n" + (if .n == 0 then "" else .text | tojson | .[1:-1] end)
JQ
)" -r \
	--argjson max_items "$MAX_ITEMS" \
	--argjson max_chars "$MAX_CHARS" \
	--arg include_dead_ends "$INCLUDE_DEAD_ENDS" \
	--arg include_open_questions "$INCLUDE_OPEN_QUESTIONS" 2>/dev/null) || OUTPUT=""

N="" TOTAL="" BODY=""
{ IFS= read -r N; IFS= read -r TOTAL; IFS= read -r BODY; } <<<"$OUTPUT"

if [[ ! "$N" =~ ^[0-9]+$ || ! "$TOTAL" =~ ^[0-9]+$ ]]; then
	[[ -n "$MARK" ]] && rm -f "$MARK"
	_emit ""
	hook_health_exit 0
fi

_emit_rendered "$N" "$TOTAL" "$BODY"

# Written beside the stamp, given its mtime, then renamed into place, so a
# reader never sees a partial cache or one stamped later than its read.
if [[ -n "$MARK" ]]; then
	if printf '%s\n%s\n%s\n%s\n' "$CACHE_KEY" "$N" "$TOTAL" "$BODY" >"${MARK}.tmp" 2>/dev/null \
		&& touch -r "$MARK" "${MARK}.tmp" 2>/dev/null; then
		mv -f "${MARK}.tmp" "$CACHE_FILE" 2>/dev/null || rm -f "${MARK}.tmp"
	else
		rm -f "${MARK}.tmp"
	fi
	rm -f "$MARK"
fi

hook_health_exit 0

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
# The rendered list is cached per project in .inject-cache, and the writers that
# run just before a SessionStart warm it (ONL-260). archivist-inject-cache.sh
# owns the render, the cache and when it may answer.

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
# shellcheck source=../lib/archivist-inject-cache.sh
source "${PLUGIN_ROOT}/scripts/lib/archivist-inject-cache.sh"

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

INPUT=$(cat)
hook_health_context "$INPUT"

FIELDS=$(printf '%s' "$INPUT" | jq -r '
	[(.cwd // ""), (.source // "startup")]
	| map(tostring | gsub("[\u001f\n]"; " "))
	| join("\u001f")' 2>/dev/null) || FIELDS=""
CWD="" SOURCE=""
IFS=$'\x1f' read -r CWD SOURCE <<<"$FIELDS" || true
[[ -n "$FIELDS" ]] || SOURCE="startup"

onlooker_project_resolve "$CWD"
PROJECT_KEY="$ONLOOKER_PROJECT_KEY"

archivist_config_load "$CWD"

if [[ -z "$PROJECT_KEY" ]]; then
	_emit ""
	hook_health_exit 0
fi

archivist_inject_cache_prepare "$PROJECT_KEY"

if ! archivist_inject_cache_read && ! archivist_inject_cache_build "$PROJECT_KEY"; then
	_emit ""
	hook_health_exit 0
fi

_emit_rendered "$ARCHIVIST_INJECT_N" "$ARCHIVIST_INJECT_TOTAL" "$ARCHIVIST_INJECT_BODY"

hook_health_exit 0

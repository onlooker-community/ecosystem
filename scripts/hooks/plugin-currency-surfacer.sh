#!/usr/bin/env bash
# Onlooker Plugin Currency Surfacer
# Invoked by SessionStart (matcher: *).
#
# Warns when the plugin code this session is about to run is not the code on
# main. See docs/superpowers/specs/2026-09-12-plugin-currency-surfacer-design.md
#
# THE AGE RULE governs every output path: absence of a finding in an EXPIRED
# cache is not evidence of currency. Past the ttl this hook says "unchecked",
# never "current". A detector that answers from a stale cache without saying so
# recreates the outage it exists to catch.
#
# Hook contract:
#   - Always exits 0. Never blocks session start.
#   - Always prints a valid hookSpecificOutput envelope, even when silent.

set -uo pipefail # No -e: never block session startup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib/hook-health.sh
source "$SCRIPT_DIR/../lib/hook-health.sh"
hook_health_register "plugin-currency-surfacer"

# shellcheck source=../lib/validate-path.sh
source "$SCRIPT_DIR/../lib/validate-path.sh"
# shellcheck source=../lib/onlooker-schema.sh
source "$SCRIPT_DIR/../lib/onlooker-schema.sh"
# shellcheck source=../lib/plugin-currency-config.sh
source "$SCRIPT_DIR/../lib/plugin-currency-config.sh"
# shellcheck source=../lib/plugin-currency-cache.sh
source "$SCRIPT_DIR/../lib/plugin-currency-cache.sh"
# shellcheck source=../lib/onlooker-project-key.sh
source "$SCRIPT_DIR/../lib/onlooker-project-key.sh"

_envelope() {
	jq -cn --arg ctx "${1:-}" '{
		hookSpecificOutput: {
			hookEventName: "SessionStart",
			additionalContext: $ctx
		}
	}'
}

_emit() {
	local event_type="$1" payload="$2" params event
	params=$(jq -n \
		--arg plugin "${ONLOOKER_PLUGIN_NAME:-onlooker}" \
		--arg sid "$SESSION_ID" \
		--arg type "$event_type" \
		--argjson payload "$payload" \
		'{plugin: $plugin, session_id: $sid, event_type: $type, payload: $payload}') || return 0
	event=$(printf '%s' "$params" | ONLOOKER_DIR="$ONLOOKER_DIR" \
		ONLOOKER_PLUGIN_NAME="${ONLOOKER_PLUGIN_NAME:-onlooker}" \
		node "${_ONLOOKER_EVENT_JS:-${CLAUDE_PLUGIN_ROOT:-}/scripts/lib/onlooker-event.mjs}" emit 2>/dev/null) || return 0
	[[ -n "$event" ]] && onlooker_append_event "$event"
	return 0
}

_finish() {
	_envelope "${1:-}"
	exit 0
}

INPUT=$(cat 2>/dev/null || true)
hook_health_context "$INPUT"

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

REPO_ROOT=$(onlooker_project_repo_root "$CWD")
plugin_currency_config_load "$REPO_ROOT"

[[ "$(plugin_currency_config_get '.plugin_currency.enabled')" == "false" ]] && {
	_emit "onlooker.currency.skipped" '{"skip_reason":"disabled"}'
	_finish ""
}

PROJECT_KEY=$(onlooker_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && {
	_emit "onlooker.currency.skipped" '{"skip_reason":"no_git_context"}'
	_finish ""
}

TTL=$(plugin_currency_config_get '.plugin_currency.probe_ttl_hours')
[[ -z "$TTL" ]] && TTL=6
BUDGET_MS=$(plugin_currency_config_get '.plugin_currency.wall_clock_budget_ms')
[[ -z "$BUDGET_MS" ]] && BUDGET_MS=1500
MAX_CHARS=$(plugin_currency_config_get '.plugin_currency.max_pointer_chars')
[[ -z "$MAX_CHARS" ]] && MAX_CHARS=200
SURFACE_CURRENT=$(plugin_currency_config_get '.plugin_currency.surface_when_current')

CACHE=$(plugin_currency_cache_path "$PROJECT_KEY")

# Render one line from a findings array plus the age of the answer. Only ever
# called with an answer we know is fresh.
_render() {
	local findings="$1" age="$2" n subject reason line human
	n=$(printf '%s' "$findings" | jq -r 'length' 2>/dev/null) || n=0
	[[ "$n" -eq 0 ]] && return 0
	reason=$(printf '%s' "$findings" | jq -r '.[0].reason // "stale_install"')
	subject=$(printf '%s' "$findings" | jq -r '.[0].subject // "a plugin"')
	if [[ "$age" -lt 3600 ]]; then human="$((age / 60))m"; else human="$((age / 3600))h"; fi
	if [[ "$n" -gt 1 ]]; then
		line="onlooker: ${n} plugin-currency findings, first ${reason} on ${subject} (checked ${human} ago) — /plugin to update"
	else
		line="onlooker: ${reason} on ${subject} (checked ${human} ago) — /plugin to update"
	fi
	printf '%.*s' "$MAX_CHARS" "$line"
}

if plugin_currency_cache_is_fresh "$CACHE" "$TTL"; then
	AGE=$(plugin_currency_cache_age_seconds "$CACHE")
	FINDINGS=$(jq -c '.findings // []' "$CACHE" 2>/dev/null) || FINDINGS='[]'
	COUNT=$(printf '%s' "$FINDINGS" | jq -r 'length' 2>/dev/null) || COUNT=0

	_emit "onlooker.currency.skipped" \
		"$(jq -cn --arg a "$AGE" '{skip_reason:"cache_fresh", answer_age_seconds:($a|tonumber)}')"

	if [[ "$COUNT" -gt 0 ]]; then
		_emit "onlooker.currency.stale" \
			"$(jq -cn --argjson f "$FINDINGS" --arg a "$AGE" \
				'{findings_count:($f|length), answer_age_seconds:($a|tonumber), findings:$f}')"
		_finish "$(_render "$FINDINGS" "$AGE")"
	fi

	if [[ "$SURFACE_CURRENT" == "true" ]]; then
		_finish "onlooker: plugin pins current (checked $((AGE / 60))m ago)"
	fi
	_finish ""
fi

# Not fresh. The live probe costs roughly 4.6s against the network, so it runs
# DETACHED and lands for the NEXT session rather than blocking this one.
# Blocking SessionStart on it would be the same defect ecosystem-449.43 files
# against scribe-stop. The age rule is what makes this safe: until that answer
# arrives we say "unchecked", never "current".
MARKETS=()
while IFS= read -r m; do
	[[ -n "$m" ]] && MARKETS+=("$m")
done < <(plugin_currency_config_get_json '.plugin_currency.marketplaces' 2>/dev/null | jq -r '.[]? // empty' 2>/dev/null)

PROBE_TIMEOUT=$(plugin_currency_config_get '.plugin_currency.probe_timeout_seconds')
[[ -z "$PROBE_TIMEOUT" ]] && PROBE_TIMEOUT=30

# mkdir is the atomic test-and-set here: if another session already has a
# refresh in flight, this one does not pile a second onto it.
_spawn_refresh() {
	local lock="${CACHE}.refresh.lock"
	mkdir -p "$(dirname "$CACHE")" 2>/dev/null
	mkdir "$lock" 2>/dev/null || return 1
	(
		trap 'rmdir "$lock" 2>/dev/null || true' EXIT
		PLUGIN_CURRENCY_SESSION_ID="$SESSION_ID" \
			ONLOOKER_DIR="$ONLOOKER_DIR" \
			CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}" \
			bash "${SCRIPT_DIR}/../lib/plugin-currency-probe.sh" \
			"$CWD" "$CACHE" "$PROBE_TIMEOUT" "${MARKETS[@]}"
	) >/dev/null 2>&1 &
	disown 2>/dev/null || true
	return 0
}

_spawn_refresh || true

PREV_AGE=$(plugin_currency_cache_age_seconds "$CACHE")
if [[ -n "$PREV_AGE" ]]; then
	# Deliberately no skipped event here. The probe has not failed -- it has not
	# finished. skip_reason has no value for "deferred", and stamping
	# probe_failed would conflate two different conditions, which is the exact
	# mistake ecosystem-449.39 records against librarian.scan.complete and which
	# this event type's own schema description warns about. The detached probe
	# emits onlooker.currency.checked when it lands; that is the record.
	_finish "onlooker: plugin currency unchecked for $((PREV_AGE / 3600))h, refreshing in the background"
fi

# No cache at all yet, and the probe is still running. Nothing truthful to say.
_finish ""

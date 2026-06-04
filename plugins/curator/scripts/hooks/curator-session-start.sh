#!/usr/bin/env bash
# Curator SessionStart hook.
#
# Runs cheap-tier checks against the typed memory store and emits findings
# under ~/.onlooker/curator/<project-key>/findings/. Surfaces a one-line
# pointer to /curator review when open findings exist.
#
# Hook contract:
#   - Always exits 0. Never blocks session start.
#   - Emits valid hookSpecificOutput JSON even when nothing to inject.
#   - No-ops when curator.enabled is not true.
#   - No-ops when no git context, no memory store path, or no checks pass
#     the rate gate.
#
# LLM contradiction sweep is deferred to a follow-up commit.

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

# shellcheck source=../lib/curator-config.sh
source "${PLUGIN_ROOT}/scripts/lib/curator-config.sh"
# shellcheck source=../lib/curator-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/curator-project-key.sh"
# shellcheck source=../lib/curator-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/curator-ulid.sh"
# shellcheck source=../lib/curator-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/curator-storage.sh"
# shellcheck source=../lib/curator-emit.sh
source "${PLUGIN_ROOT}/scripts/lib/curator-emit.sh"
# shellcheck source=../lib/curator-memory-reader.sh
source "${PLUGIN_ROOT}/scripts/lib/curator-memory-reader.sh"
# shellcheck source=../lib/curator-checks.sh
source "${PLUGIN_ROOT}/scripts/lib/curator-checks.sh"

_emit() {
	local context="${1:-}"
	jq -cn --arg ctx "$context" '{
		hookSpecificOutput: {
			hookEventName: "SessionStart",
			additionalContext: $ctx
		}
	}'
}

INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

REPO_ROOT=$(curator_project_repo_root "$CWD")
curator_config_load "$REPO_ROOT"

if ! curator_config_enabled; then
	_emit ""
	exit 0
fi

PROJECT_KEY=$(curator_project_key "$CWD")
if [[ -z "$PROJECT_KEY" ]]; then
	_emit ""
	exit 0
fi

curator_storage_init "$PROJECT_KEY" || { _emit ""; exit 0; }
REMOTE_URL=$(curator_project_remote_url "$CWD")
curator_storage_write_manifest "$PROJECT_KEY" "$REMOTE_URL" "$REPO_ROOT" || true

# ----------------------------------------------------------------------------
# Resolve the typed memory store path. Skip the audit if it can't be resolved.
# ----------------------------------------------------------------------------

MEM_PATH_TEMPLATE=$(curator_config_get '.curator.memory_store_path')
if [[ -z "$MEM_PATH_TEMPLATE" || "$MEM_PATH_TEMPLATE" == "null" ]]; then
	MEM_PATH_TEMPLATE='${HOME}/.claude/projects/${CLAUDE_PROJECT_ENCODED}/memory'
fi
MEM_DIR=$(curator_memory_resolve_path "$MEM_PATH_TEMPLATE")

if [[ -z "$MEM_DIR" || ! -d "$MEM_DIR" ]]; then
	# No memory store, nothing to audit. Still emit a scan event so the
	# observability stream shows curator ran.
	curator_emit "curator.scan.started" "$SESSION_ID" "$(jq -cn '{ mode: "cheap" }')"
	curator_emit "curator.scan.complete" "$SESSION_ID" "$(jq -cn '{
		mode: "cheap", outcome: "ok",
		findings_new: 0, findings_resolved: 0, duration_ms: 0
	}')"
	_emit ""
	exit 0
fi

# ----------------------------------------------------------------------------
# Cheap-tier rate gate.
#
# Three knobs:
#   cheap_checks.enabled            global on/off for the cheap tier
#   cheap_checks.wall_clock_budget_ms   abort phases past this elapsed
#   surfacer.max_pointer_chars      truncate additionalContext at this
# ----------------------------------------------------------------------------

CHEAP_ENABLED=$(curator_config_get '.curator.cheap_checks.enabled')
SCAN_START_MS=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) \
	|| SCAN_START_MS=$(($(date +%s) * 1000))
SCAN_START_S=$((SCAN_START_MS / 1000))

curator_emit "curator.scan.started" "$SESSION_ID" "$(jq -cn '{ mode: "cheap" }')"

if [[ "$CHEAP_ENABLED" == "false" ]]; then
	# Cheap tier explicitly off — emit scan.complete with skip_reason
	# and skip straight to the surfacer (which reads previously-persisted
	# findings, if any).
	curator_emit "curator.scan.complete" "$SESSION_ID" "$(jq -cn \
		--arg mode "cheap" --arg outcome "skipped" \
		--arg skip_reason "disabled" \
		--argjson findings_new 0 --argjson findings_resolved 0 \
		--argjson duration_ms 0 \
		'{ mode: $mode, outcome: $outcome, skip_reason: $skip_reason,
		   findings_new: $findings_new, findings_resolved: $findings_resolved,
		   duration_ms: $duration_ms }')"
	FINDINGS_NEW=0
	# Skip the per-check pipeline; fall through to the surfacer.
	OUTCOME_FOR_SCAN_COMPLETE="skipped"
else
	OUTCOME_FOR_SCAN_COMPLETE="ok"
fi

BUDGET_MS=$(curator_config_get '.curator.cheap_checks.wall_clock_budget_ms')
[[ -z "$BUDGET_MS" || "$BUDGET_MS" == "null" ]] && BUDGET_MS=500

_curator_now_ms() {
	python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null \
		|| echo "$(( $(date +%s) * 1000 ))"
}

_curator_over_budget() {
	local now elapsed
	now=$(_curator_now_ms)
	elapsed=$((now - SCAN_START_MS))
	(( elapsed > BUDGET_MS ))
}

# When the cheap tier is enabled, run the four checks under the budget
# gate. Each phase checks the budget BEFORE its work — partial phases
# are allowed to finish since check work itself is cheap.
DATE_FINDINGS='[]'
PATH_FINDINGS='[]'
BROKEN_INDEX='[]'
ORPHANED='[]'
BUDGET_TRIPPED="false"
MEMORIES='[]'

if [[ "$CHEAP_ENABLED" != "false" ]]; then
	if _curator_over_budget; then
		BUDGET_TRIPPED="true"
	else
		MEMORIES=$(curator_memory_load_all "$MEM_DIR")
	fi

	DATE_GRACE=$(curator_config_get '.curator.date_check.date_grace_period_days')
	[[ -z "$DATE_GRACE" || "$DATE_GRACE" == "null" ]] && DATE_GRACE=14
	DATE_CHECK_ENABLED=$(curator_config_get '.curator.date_check.enabled')

	if [[ "$BUDGET_TRIPPED" != "true" && "$DATE_CHECK_ENABLED" != "false" ]]; then
		if _curator_over_budget; then
			BUDGET_TRIPPED="true"
		else
			DATE_FINDINGS=$(curator_check_dates "$MEMORIES" "$DATE_GRACE") || DATE_FINDINGS='[]'
		fi
	fi

	REF_CHECK_ENABLED=$(curator_config_get '.curator.reference_check.enabled')
	if [[ "$BUDGET_TRIPPED" != "true" && "$REF_CHECK_ENABLED" != "false" && -n "$REPO_ROOT" ]]; then
		if _curator_over_budget; then
			BUDGET_TRIPPED="true"
		else
			PATH_FINDINGS=$(curator_check_paths "$MEMORIES" "$REPO_ROOT") || PATH_FINDINGS='[]'
		fi
	fi

	if [[ "$BUDGET_TRIPPED" != "true" ]]; then
		if _curator_over_budget; then
			BUDGET_TRIPPED="true"
		else
			BROKEN_INDEX=$(curator_check_broken_index "$MEMORIES")
			ORPHANED=$(curator_check_orphaned "$MEMORIES")
		fi
	fi
fi

# ----------------------------------------------------------------------------
# Persist findings (with dedup by deduped_hash) and emit per-finding events.
# Skipped entirely when the cheap tier is disabled — the disabled path above
# already emitted scan.complete and set FINDINGS_NEW=0.
# ----------------------------------------------------------------------------

NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
[[ "$CHEAP_ENABLED" == "false" ]] || FINDINGS_NEW=0

_write_finding() {
	local kind="$1"
	local payload="$2"
	local hash_input
	hash_input="${kind}|$(printf '%s' "$payload" | jq -cS '.')"
	local hash
	hash=$(curator_finding_hash "$hash_input") || hash=""
	[[ -z "$hash" ]] && return 0

	# Dedup: skip if an open finding with the same hash already exists.
	if curator_storage_has_finding_with_hash "$PROJECT_KEY" "$hash"; then
		return 0
	fi

	local id record
	id=$(curator_ulid)
	record=$(jq -n \
		--arg id "$id" \
		--arg kind "$kind" \
		--arg created_at "$NOW_TS" \
		--arg deduped_hash "$hash" \
		--argjson detail "$payload" \
		'{
			id: $id, kind: $kind, created_at: $created_at,
			status: "open", deduped_hash: $deduped_hash, detail: $detail
		}')
	curator_storage_write_finding "$PROJECT_KEY" "$id" "$record" >/dev/null || return 0
	FINDINGS_NEW=$((FINDINGS_NEW + 1))

	# Per-kind event payload.
	local event_type event_payload
	event_type="curator.finding.${kind}"
	event_payload=$(jq -cn --arg fid "$id" --argjson detail "$payload" \
		'{ finding_id: $fid } + $detail')
	curator_emit "$event_type" "$SESSION_ID" "$event_payload"
}

# Convert each finding-array entry into a stored + emitted finding.
_emit_kind_findings() {
	local kind="$1" findings_json="$2"
	local n
	n=$(printf '%s' "$findings_json" | jq 'length' 2>/dev/null) || n=0
	local i payload
	for ((i = 0; i < n; i++)); do
		payload=$(printf '%s' "$findings_json" | jq -c ".[$i]")
		[[ -z "$payload" || "$payload" == "null" ]] && continue
		_write_finding "$kind" "$payload"
	done
}

if [[ "$CHEAP_ENABLED" != "false" ]]; then
	_emit_kind_findings "date_decayed" "$DATE_FINDINGS"
	_emit_kind_findings "path_broken" "$PATH_FINDINGS"
	_emit_kind_findings "broken_index" "$BROKEN_INDEX"
	_emit_kind_findings "orphaned_memory" "$ORPHANED"
fi

# ----------------------------------------------------------------------------
# Watermark + scan.complete. The disabled-tier branch above already emitted
# scan.complete; this branch fires only when the cheap tier ran (success or
# budget tripped).
# ----------------------------------------------------------------------------

if [[ "$CHEAP_ENABLED" != "false" ]]; then
	curator_storage_write_watermark "$(curator_last_cheap_scan_path "$PROJECT_KEY")" || true

	DURATION_MS=$(( $(_curator_now_ms) - SCAN_START_MS ))
	if [[ "$BUDGET_TRIPPED" == "true" ]]; then
		curator_emit "curator.scan.complete" "$SESSION_ID" "$(jq -cn \
			--arg mode "cheap" --arg outcome "skipped" \
			--arg skip_reason "over_budget" \
			--argjson findings_new "$FINDINGS_NEW" \
			--argjson findings_resolved 0 \
			--argjson duration_ms "$DURATION_MS" \
			'{ mode: $mode, outcome: $outcome, skip_reason: $skip_reason,
			   findings_new: $findings_new,
			   findings_resolved: $findings_resolved,
			   duration_ms: $duration_ms }')"
	else
		curator_emit "curator.scan.complete" "$SESSION_ID" "$(jq -cn \
			--arg mode "cheap" --arg outcome "ok" \
			--argjson findings_new "$FINDINGS_NEW" \
			--argjson findings_resolved 0 \
			--argjson duration_ms "$DURATION_MS" \
			'{ mode: $mode, outcome: $outcome,
			   findings_new: $findings_new,
			   findings_resolved: $findings_resolved,
			   duration_ms: $duration_ms }')"
	fi
fi

# ----------------------------------------------------------------------------
# Surfacer.
# ----------------------------------------------------------------------------

SKIP_WHEN_ZERO=$(curator_config_get '.curator.surfacer.skip_when_zero')
[[ -z "$SKIP_WHEN_ZERO" || "$SKIP_WHEN_ZERO" == "null" ]] && SKIP_WHEN_ZERO="true"

OPEN_COUNT=$(curator_storage_count_open "$PROJECT_KEY")
[[ -z "$OPEN_COUNT" || "$OPEN_COUNT" == "null" ]] && OPEN_COUNT=0

if [[ "$OPEN_COUNT" -eq 0 && "$SKIP_WHEN_ZERO" == "true" ]]; then
	_emit ""
	exit 0
fi

# Build a compact "2 path-broken, 1 date-decayed" descriptor for the
# pointer message.
COUNTS_BY_KIND=$(curator_storage_open_counts_by_kind "$PROJECT_KEY")
SUMMARY=$(printf '%s' "$COUNTS_BY_KIND" | jq -r '
	map( (.count|tostring) + " " + (.kind | gsub("_"; "-")) )
	| join(", ")
')

CONTEXT=$(printf 'Curator: %s open finding%s (%s). Review with `/curator review`.' \
	"$OPEN_COUNT" \
	"$([ "$OPEN_COUNT" -eq 1 ] && echo "" || echo "s")" \
	"$SUMMARY")

# Cap the pointer length so a long per-kind summary never overflows the
# user's SessionStart context.
MAX_POINTER=$(curator_config_get '.curator.surfacer.max_pointer_chars')
[[ -z "$MAX_POINTER" || "$MAX_POINTER" == "null" ]] && MAX_POINTER=200
if [[ "${#CONTEXT}" -gt "$MAX_POINTER" ]]; then
	# Reserve room for the truncation ellipsis without exceeding the cap.
	TRUNC=$((MAX_POINTER - 1))
	(( TRUNC < 1 )) && TRUNC=1
	CONTEXT="${CONTEXT:0:TRUNC}…"
fi

_emit "$CONTEXT"
exit 0

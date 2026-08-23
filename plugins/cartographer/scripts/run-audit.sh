#!/usr/bin/env bash
# run-audit.sh — Cartographer audit pipeline (5 phases).
#
# Intended to run as a detached background process launched by the SessionStart
# hook. Also called directly by the /cartographer skill (foreground).
#
# Phases:
#   1. discover   — collect all auditable files
#   2. extract    — per-file content hash (incremental cache key)
#   3. relate     — contradiction + dead_rule analysis (LLM)
#   4. synthesize — stale_ref + scope_collision + undocumented_entity + hash
#   5. emit       — persist findings atomically, emit events for new findings
#
# Environment:
#   CARTOGRAPHER_DIR    — state directory (~/.onlooker/cartographer/<project_key>)
#   CARTOGRAPHER_TRIGGER — "session_start_interval" | "session_start_first_run" | "post_tool_use" | "manual"
#   CARTOGRAPHER_TARGET_FILE — (optional) single file for targeted post-write audit
#   CLAUDE_PLUGIN_ROOT  — plugin root directory
#
# Invariant: last_audit_at is written ONLY on full successful completion of all
# phases. Partial runs leave last_audit_at unchanged so the next session retries.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

source "$PLUGIN_ROOT/scripts/lib/cartographer-config.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-ulid.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-project-key.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-events.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-resolve.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-filter.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-collect.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-omission.sh"

CARTOGRAPHER_DIR="${CARTOGRAPHER_DIR:?CARTOGRAPHER_DIR must be set}"
TRIGGER="${CARTOGRAPHER_TRIGGER:-manual}"
TARGET_FILE="${CARTOGRAPHER_TARGET_FILE:-}"
REPO_ROOT="${CARTOGRAPHER_REPO_ROOT:-$(pwd)}"
TYPE_FILTER="${CARTOGRAPHER_TYPE_FILTER:-}"
SCOPE_PATH="${CARTOGRAPHER_SCOPE_PATH:-}"
AUDIT_ID=$(cartographer_ulid)
START_TS=$(date +%s)

_TIMEOUT_CMD=$(command -v gtimeout 2>/dev/null || command -v timeout 2>/dev/null || printf 'timeout')

FINDINGS_DIR="$CARTOGRAPHER_DIR/findings"
DEDUP_DIR="$CARTOGRAPHER_DIR/dedup"
RUNS_DIR="$CARTOGRAPHER_DIR/runs"
mkdir -p "$FINDINGS_DIR" "$DEDUP_DIR" "$RUNS_DIR"

PHASES_COMPLETED=()
PHASES_FAILED=()
ALL_FINDINGS="[]"

# Load config before any accessor runs. Without this every accessor below falls
# through to its hardcoded default, so exclude_paths, the timeouts, the models,
# and the token caps were all silently unconfigurable — the orchestrator was the
# one place that never loaded (ecosystem-88v).
#
# This is the single load for the whole audit. The analysis sub-shells take
# their settings as positional parameters and read no config of their own, so
# the values resolved here are the ones that take effect everywhere.
cartographer_config_load "$REPO_ROOT"

_phase_timeout=$(cartographer_config_phase_timeout)
_total_timeout=$(cartographer_config_total_timeout)
log() { printf '[cartographer] %s\n' "$*" >>"$CARTOGRAPHER_DIR/audit.log" 2>&1; }
[[ "$_total_timeout" -lt $(( _phase_timeout * 3 )) ]] && \
	log "warning: total_timeout_seconds=${_total_timeout} is less than 3× phase_timeout_seconds=${_phase_timeout}; phases may be killed early"
_model_extraction=$(cartographer_config_model_extraction)
_model_synthesis=$(cartographer_config_model_synthesis)
_max_tokens_extraction=$(cartographer_config_max_output_tokens_extraction)
_max_tokens_synthesis=$(cartographer_config_max_output_tokens_synthesis)
_exclude_json=$(cartographer_config_exclude_paths)
_undocumented_enabled=$(cartographer_config_undocumented_enabled)
_undocumented_globs=$(cartographer_config_undocumented_globs)
_undocumented_exclude=$(cartographer_config_undocumented_exclude)
_undocumented_max=$(cartographer_config_undocumented_max_findings)

emit_safe() {
	cartographer_emit_event "$1" "$2" 2>>"$CARTOGRAPHER_DIR/audit.log" || true
}

# Announce one finding the resolution sweep retired.
#
# Passed to cartographer_resolve_absent_findings by name rather than called
# after it, so the announcement happens inside the sweep's own guards — a run
# that must not resolve cannot announce either. Handing over a function name
# also keeps cartographer-resolve.sh free of any dependency on the event bus.
_emit_resolved() {
	emit_safe "cartographer.issue.resolved" \
		"$(cartographer_issue_resolved_payload "$AUDIT_ID" "$1")"
}

# Reject an unrecognized type rather than filtering everything away. An empty
# audit is indistinguishable from a clean repo, so a typo would read as good
# news — the same class of silent-nothing this flag was filed for.
if [[ -n "$TYPE_FILTER" ]] && ! cartographer_filter_valid_type "$TYPE_FILTER"; then
	log "error: unknown type filter '${TYPE_FILTER}' (expected one of: ${CARTOGRAPHER_FINDING_TYPES})"
	exit 1
fi
[[ -n "$TYPE_FILTER" ]] && log "filter type=${TYPE_FILTER}"
[[ -n "$SCOPE_PATH" ]] && log "filter scope=${SCOPE_PATH}"

# ── Phase 1: Discover ──────────────────────────────────────────────────────────
run_discover() {
	log "phase=discover starting"
	local repo_root="$REPO_ROOT"

	if [[ -n "$TARGET_FILE" ]]; then
		# Targeted post-write audit: only the modified file
		DISCOVERED_FILES=$(jq -n --arg f "$TARGET_FILE" '[$f]')
		GLOBAL_FILES="[]"
	else
		local raw_files
		raw_files=$(cartographer_collect_files "$repo_root" "$_exclude_json" 5)
		DISCOVERED_FILES=$(printf '%s\n' "$raw_files" | grep -v '^$' | jq -R . | jq -s .)
		local raw_global
		raw_global=$(cartographer_collect_global_files)
		GLOBAL_FILES=$(printf '%s\n' "$raw_global" | grep -v '^$' | jq -R . | jq -s .)
	fi

	# Scope narrows what gets analyzed, not what the repo root is: stale_ref
	# resolves path tokens against the real root, and re-rooting would make
	# every reference outside the scope look broken.
	if [[ -n "$SCOPE_PATH" ]]; then
		DISCOVERED_FILES=$(cartographer_filter_scope \
			"$DISCOVERED_FILES" "$REPO_ROOT" "$SCOPE_PATH")
	fi

	local file_count
	file_count=$(printf '%s' "$DISCOVERED_FILES" | jq 'length')
	log "phase=discover files=${file_count}"
	PHASES_COMPLETED+=("discover")
}

# ── Phase 2: Extract ───────────────────────────────────────────────────────────
run_extract() {
	log "phase=extract starting"
	local cached=0 computed=0

	EXTRACT_CACHE="{}"
	while IFS= read -r fpath; do
		[[ -z "$fpath" || ! -f "$fpath" ]] && continue
		local fhash
		fhash=$(cartographer_file_content_hash "$fpath") || continue
		local cache_file="$CARTOGRAPHER_DIR/extracts/${fhash}.json"

		if [[ -f "$cache_file" ]]; then
			(( cached++ )) || true
		else
			mkdir -p "$CARTOGRAPHER_DIR/extracts"
			printf '{"path":"%s","hash":"%s"}' "$fpath" "$fhash" >"${cache_file}.tmp"
			mv -f "${cache_file}.tmp" "$cache_file"
			(( computed++ )) || true
		fi
		EXTRACT_CACHE=$(printf '%s' "$EXTRACT_CACHE" \
			| jq --arg p "$fpath" --arg h "$fhash" '.[$p]=$h')
	done < <(printf '%s' "$DISCOVERED_FILES" | jq -r '.[]' 2>/dev/null)

	log "phase=extract cached=${cached} computed=${computed}"
	PHASES_COMPLETED+=("extract")
}

# ── Phase 3: Relate (contradiction + dead_rule) ────────────────────────────────
run_relate() {
	log "phase=relate starting"

	# One LLM pass emits both contradiction and dead_rule, so asking for either
	# runs it and the unwanted type is filtered out of the result below.
	if ! cartographer_filter_wants "contradiction" "$TYPE_FILTER"; then
		log "phase=relate skipped by type filter"
		RELATE_FINDINGS="[]"
		PHASES_COMPLETED+=("relate")
		return 0
	fi

	local findings
	findings=$($_TIMEOUT_CMD "$_phase_timeout" bash -c \
		"source '$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh'
		 cartographer_analyze_contradiction '$DISCOVERED_FILES' \
		   '$_model_extraction' '$_max_tokens_extraction' '$_phase_timeout'" \
		2>>"$CARTOGRAPHER_DIR/audit.log") || {
		log "phase=relate timeout or error"
		PHASES_FAILED+=("relate")
		return 1
	}
	RELATE_FINDINGS=$(cartographer_filter_findings "${findings:-[]}" "$TYPE_FILTER")
	local count
	count=$(printf '%s' "$RELATE_FINDINGS" | jq 'length' 2>/dev/null || printf '0')
	log "phase=relate findings=${count}"
	PHASES_COMPLETED+=("relate")
}

# ── Phase 4: Synthesize (stale_ref + scope_collision + hash) ──────────────────
run_synthesize() {
	log "phase=synthesize starting"

	# Each analyzer skipped under a type filter is an LLM call not made, which
	# is where the flag earns its keep.
	local stale_findings="[]" scope_findings="[]"
	if cartographer_filter_wants "stale_ref" "$TYPE_FILTER"; then
		stale_findings=$($_TIMEOUT_CMD "$_phase_timeout" bash -c \
			"source '$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh'
			 cartographer_analyze_stale_ref '$DISCOVERED_FILES' '$REPO_ROOT' \
			   '$_model_synthesis' '$_max_tokens_synthesis' '$_phase_timeout'" \
			2>>"$CARTOGRAPHER_DIR/audit.log") || stale_findings="[]"
	fi

	if cartographer_filter_wants "scope_collision" "$TYPE_FILTER"; then
		scope_findings=$($_TIMEOUT_CMD "$_phase_timeout" bash -c \
			"source '$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh'
			 cartographer_analyze_scope_collision '$GLOBAL_FILES' '$DISCOVERED_FILES' \
			   '$_model_synthesis' '$_max_tokens_synthesis' '$_phase_timeout'" \
			2>>"$CARTOGRAPHER_DIR/audit.log") || scope_findings="[]"
	fi

	# Disk → doc. Skipped on targeted post-write audits: DISCOVERED_FILES is a
	# single file there, so grepping it for every entity name would report
	# nearly the whole enumeration as undocumented, and the emit phase would
	# dedup-sentinel those false findings permanently. scope_collision already
	# no-ops on targeted runs for the same reason.
	local omission_findings="[]"
	if [[ -z "$TARGET_FILE" && "$_undocumented_enabled" == "true" ]] \
		&& cartographer_filter_wants "undocumented_entity" "$TYPE_FILTER"; then
		omission_findings=$($_TIMEOUT_CMD "$_phase_timeout" bash -c \
			"source '$PLUGIN_ROOT/scripts/lib/cartographer-omission.sh'
			 cartographer_analyze_undocumented_entity '$DISCOVERED_FILES' '$REPO_ROOT' \
			   '$_undocumented_globs' '$_undocumented_exclude' '$_undocumented_max'" \
			2>>"$CARTOGRAPHER_DIR/audit.log") || omission_findings="[]"
	fi

	# Merge all raw findings
	local raw_all
	raw_all=$(jq -n \
		--argjson relate "${RELATE_FINDINGS:-[]}" \
		--argjson stale "${stale_findings:-[]}" \
		--argjson scope "${scope_findings:-[]}" \
		--argjson omission "${omission_findings:-[]}" \
		'$relate + $stale + $scope + $omission')

	# Add finding_hash to each finding
	ALL_FINDINGS="[]"
	local idx=0
	while IFS= read -r finding; do
		[[ -z "$finding" ]] && continue
		local ftype ffile_a fexcerpt_a ffile_b fexcerpt_b
		# `// ""` collapses absent, null and empty into one check, the same way
		# cartographer_issue_found_payload does — jq's `//` treats "" as
		# present, so an empty type would otherwise slip past.
		ftype=$(printf '%s' "$finding" | jq -r '.type // ""')

		# A finding with no type is malformed: every analyzer writes a literal
		# type, so this means the phase that produced it has a bug. Drop it here
		# rather than hashing it.
		#
		# This used to default to "unknown". The emit path already refused to
		# announce such a finding (ecosystem-ci0), but the orchestrator stored
		# it anyway under a hash derived from a type it does not have, and then
		# touched its dedup sentinel. That sentinel made the silence permanent:
		# every later audit saw "known", took the refresh path, and emitted
		# nothing — so the finding sat on disk forever, counted in
		# new_finding_count, and could never be announced. Dropping it keeps the
		# stored corpus honest and leaves the hash of every well-formed finding
		# untouched, so no existing dedup sentinel is orphaned (ecosystem-0ty).
		if [[ -z "$ftype" ]]; then
			log "synthesize: dropped a finding that carries no type — the analyzer that produced it has a bug"
			continue
		fi

		ffile_a=$(printf '%s' "$finding" | jq -r '.file_a // ""')
		fexcerpt_a=$(printf '%s' "$finding" | jq -r '.excerpt_a // ""')
		ffile_b=$(printf '%s' "$finding" | jq -r '.file_b // ""')
		fexcerpt_b=$(printf '%s' "$finding" | jq -r '.excerpt_b // ""')

		local fhash
		fhash=$(cartographer_finding_hash \
			"$ftype" "$ffile_a" "$fexcerpt_a" "$ffile_b" "$fexcerpt_b")

		local enriched
		enriched=$(printf '%s' "$finding" \
			| jq --arg h "$fhash" --arg aid "$AUDIT_ID" \
			  '. + {"finding_hash":$h,"audit_id":$aid}')
		ALL_FINDINGS=$(printf '%s' "$ALL_FINDINGS" \
			| jq --argjson f "$enriched" '. + [$f]')
		(( idx++ )) || true
	done < <(printf '%s' "$raw_all" | jq -c '.[]' 2>/dev/null)

	log "phase=synthesize total_findings=$(printf '%s' "$ALL_FINDINGS" | jq 'length')"
	PHASES_COMPLETED+=("synthesize")
}

# ── Phase 5: Emit ──────────────────────────────────────────────────────────────
run_emit() {
	log "phase=emit starting"
	local new_count=0 known_count=0

	while IFS= read -r finding; do
		[[ -z "$finding" ]] && continue
		local fhash
		fhash=$(printf '%s' "$finding" | jq -r '.finding_hash')
		[[ -z "$fhash" ]] && continue

		local finding_file="$FINDINGS_DIR/${fhash}.json"
		local dedup_sentinel="$DEDUP_DIR/${fhash}"
		local now
		now=$(date +%s)

		if [[ -f "$dedup_sentinel" ]]; then
			# Known finding — refresh it atomically, no bus event. Refreshing
			# also reopens it; see cartographer_refresh_finding for why that is
			# load-bearing rather than tidiness.
			(( known_count++ )) || true
			cartographer_refresh_finding "$finding_file" "$now" || true
		else
			# New finding — write file atomically, emit bus event, then mark dedup
			local with_ts
			with_ts=$(printf '%s' "$finding" \
				| jq --argjson ts "$now" '. + {"first_seen_at":$ts,"last_seen_at":$ts,"resolved":false}')
			printf '%s\n' "$with_ts" >"${finding_file}.tmp"
			mv -f "${finding_file}.tmp" "$finding_file"

			# Branch on the builder rather than passing its output straight
			# to emit_safe. A typeless finding makes it return non-zero, and
			# an unchecked substitution would hand emit_safe an empty payload
			# that cartographer_emit_event rejects silently — relocating the
			# silence this fix exists to end (ecosystem-ci0). Its stderr is
			# appended to the same audit.log emit_safe writes to, because the
			# substitution runs before emit_safe and escapes that redirect.
			local found_payload
			if found_payload=$(cartographer_issue_found_payload \
				"$AUDIT_ID" "$fhash" "$finding" 2>>"$CARTOGRAPHER_DIR/audit.log"); then
				emit_safe "cartographer.issue.found" "$found_payload"
			else
				log "emit: no issue.found for ${fhash} — finding carries no type"
			fi

			touch "$dedup_sentinel"
			(( new_count++ )) || true
		fi
	done < <(printf '%s' "$ALL_FINDINGS" | jq -c '.[]' 2>/dev/null)

	log "phase=emit new=${new_count} known=${known_count}"

	# Retire findings this run did not observe. Guarded inside against targeted
	# audits and partial runs, both of which see too little to treat absence as
	# evidence the drift is gone.
	local resolved_count
	resolved_count=$(cartographer_resolve_absent_findings \
		"$FINDINGS_DIR" "$START_TS" "$TARGET_FILE" "${#PHASES_FAILED[@]}" "" _emit_resolved)
	log "phase=emit resolved=${resolved_count}"

	# Only a run that actually swept may report a count. A targeted or partial
	# run leaves the field off entirely rather than reporting 0, which would
	# read as "swept, found nothing to retire". This asks the same predicate the
	# sweep guards on, so the two cannot drift apart on what the run proved.
	local resolved_arg=""
	if cartographer_resolution_is_sound "$TARGET_FILE" "${#PHASES_FAILED[@]}"; then
		resolved_arg="$resolved_count"
	fi

	local end_ts duration_ms total_count
	end_ts=$(date +%s)
	duration_ms=$(( (end_ts - START_TS) * 1000 ))
	total_count=$(printf '%s' "$ALL_FINDINGS" | jq 'length')

	# Write run record
	local run_file="$RUNS_DIR/audit-${AUDIT_ID}.json"
	jq -n \
		--arg audit_id "$AUDIT_ID" \
		--arg trigger "$TRIGGER" \
		--argjson new_finding_count "$new_count" \
		--argjson known_finding_count "$known_count" \
		--argjson resolved_finding_count "$resolved_count" \
		--argjson total_finding_count "$total_count" \
		--argjson duration_ms "$duration_ms" \
		--argjson phases_completed "$(printf '%s\n' "${PHASES_COMPLETED[@]}" | jq -R . | jq -s .)" \
		--argjson phases_failed "$(printf '%s\n' "${PHASES_FAILED[@]:-}" | jq -R . | jq -s .)" \
		'{"audit_id":$audit_id,"trigger":$trigger,"new_finding_count":$new_finding_count,"known_finding_count":$known_finding_count,"resolved_finding_count":$resolved_finding_count,"total_finding_count":$total_finding_count,"duration_ms":$duration_ms,"phases_completed":$phases_completed,"phases_failed":$phases_failed}' \
		>"${run_file}.tmp" && mv -f "${run_file}.tmp" "$run_file"

	emit_safe "cartographer.audit.complete" \
		"$(cartographer_audit_complete_payload \
			"$AUDIT_ID" "$TRIGGER" "$new_count" "$total_count" "$duration_ms" "$resolved_arg")"

	PHASES_COMPLETED+=("emit")
}

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
	log "audit_id=${AUDIT_ID} trigger=${TRIGGER} starting"

	run_discover || { log "discover failed"; exit 1; }
	run_extract  || { log "extract failed (non-fatal, continuing)"; }
	run_relate   || { log "relate phase failed"; PHASES_FAILED+=("relate"); }
	run_synthesize || { log "synthesize phase failed"; PHASES_FAILED+=("synthesize"); }
	run_emit || { log "emit phase failed"; exit 1; }

	# Only advance last_audit_at for full (non-targeted) audits with no failures.
	# Targeted post-write audits cover only a single file and must not reset the
	# interval gate — the next session start would otherwise skip a needed full run.
	if [[ "${#PHASES_FAILED[@]}" -eq 0 && -z "$TARGET_FILE" ]]; then
		printf '%d' "$(date +%s)" >"$CARTOGRAPHER_DIR/last_audit_at"
		log "audit_id=${AUDIT_ID} completed successfully"
	elif [[ "${#PHASES_FAILED[@]}" -gt 0 ]]; then
		log "audit_id=${AUDIT_ID} partial — last_audit_at not advanced (failed: ${PHASES_FAILED[*]})"
	else
		log "audit_id=${AUDIT_ID} targeted audit complete — last_audit_at not advanced"
	fi
}

main "$@"

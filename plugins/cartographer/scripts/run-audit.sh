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
#   4. synthesize — stale_ref + scope_collision + finding hash computation
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
source "$PLUGIN_ROOT/scripts/lib/cartographer-collect.sh"
source "$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh"

CARTOGRAPHER_DIR="${CARTOGRAPHER_DIR:?CARTOGRAPHER_DIR must be set}"
TRIGGER="${CARTOGRAPHER_TRIGGER:-manual}"
TARGET_FILE="${CARTOGRAPHER_TARGET_FILE:-}"
AUDIT_ID=$(cartographer_ulid)
START_TS=$(date +%s)

FINDINGS_DIR="$CARTOGRAPHER_DIR/findings"
DEDUP_DIR="$CARTOGRAPHER_DIR/dedup"
RUNS_DIR="$CARTOGRAPHER_DIR/runs"
mkdir -p "$FINDINGS_DIR" "$DEDUP_DIR" "$RUNS_DIR"

PHASES_COMPLETED=()
PHASES_FAILED=()
ALL_FINDINGS="[]"

_phase_timeout=$(cartographer_config_phase_timeout)
_total_timeout=$(cartographer_config_total_timeout)
_model_extraction=$(cartographer_config_model_extraction)
_model_synthesis=$(cartographer_config_model_synthesis)
_max_tokens_extraction=$(cartographer_config_max_output_tokens_extraction)
_max_tokens_synthesis=$(cartographer_config_max_output_tokens_synthesis)
_exclude_json=$(cartographer_config_exclude_paths)

log() { printf '[cartographer] %s\n' "$*" >>"$CARTOGRAPHER_DIR/audit.log" 2>&1; }

emit_safe() {
	cartographer_emit_event "$1" "$2" 2>>"$CARTOGRAPHER_DIR/audit.log" || true
}

# ── Phase 1: Discover ──────────────────────────────────────────────────────────
run_discover() {
	log "phase=discover starting"
	local repo_root
	repo_root=$(cartographer_project_repo_root "$(pwd)")

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

	local file_count
	file_count=$(printf '%s' "$DISCOVERED_FILES" | jq 'length')
	log "phase=discover files=${file_count}"
	PHASES_COMPLETED+=("discover")

	emit_safe "cartographer.audit.complete" "$(jq -n \
		--arg audit_id "$AUDIT_ID" \
		--arg trigger "$TRIGGER" \
		--argjson file_count "$file_count" \
		--arg phase "discover" \
		--arg status "started" \
		'{"audit_id":$audit_id,"trigger":$trigger,"file_count":$file_count,"phase":$phase,"status":$status}')"
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
	local findings
	findings=$(timeout "$_phase_timeout" bash -c \
		"source '$PLUGIN_ROOT/scripts/lib/cartographer-config.sh'
		 source '$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh'
		 cartographer_config_load '$(pwd)'
		 cartographer_analyze_contradiction '$DISCOVERED_FILES' \
		   '$_model_extraction' '$_max_tokens_extraction' '$_phase_timeout'" \
		2>>"$CARTOGRAPHER_DIR/audit.log") || {
		log "phase=relate timeout or error"
		PHASES_FAILED+=("relate")
		return 1
	}
	RELATE_FINDINGS="${findings:-[]}"
	local count
	count=$(printf '%s' "$RELATE_FINDINGS" | jq 'length' 2>/dev/null || printf '0')
	log "phase=relate findings=${count}"
	PHASES_COMPLETED+=("relate")
}

# ── Phase 4: Synthesize (stale_ref + scope_collision + hash) ──────────────────
run_synthesize() {
	log "phase=synthesize starting"

	local stale_findings scope_findings
	stale_findings=$(timeout "$_phase_timeout" bash -c \
		"source '$PLUGIN_ROOT/scripts/lib/cartographer-config.sh'
		 source '$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh'
		 cartographer_config_load '$(pwd)'
		 cartographer_analyze_stale_ref '$DISCOVERED_FILES' '$(pwd)' \
		   '$_model_synthesis' '$_max_tokens_synthesis' '$_phase_timeout'" \
		2>>"$CARTOGRAPHER_DIR/audit.log") || stale_findings="[]"

	scope_findings=$(timeout "$_phase_timeout" bash -c \
		"source '$PLUGIN_ROOT/scripts/lib/cartographer-config.sh'
		 source '$PLUGIN_ROOT/scripts/lib/cartographer-analyze.sh'
		 cartographer_config_load '$(pwd)'
		 cartographer_analyze_scope_collision '$GLOBAL_FILES' '$DISCOVERED_FILES' \
		   '$_model_synthesis' '$_max_tokens_synthesis' '$_phase_timeout'" \
		2>>"$CARTOGRAPHER_DIR/audit.log") || scope_findings="[]"

	# Merge all raw findings
	local raw_all
	raw_all=$(jq -n \
		--argjson relate "${RELATE_FINDINGS:-[]}" \
		--argjson stale "${stale_findings:-[]}" \
		--argjson scope "${scope_findings:-[]}" \
		'$relate + $stale + $scope')

	# Add finding_hash to each finding
	ALL_FINDINGS="[]"
	local idx=0
	while IFS= read -r finding; do
		[[ -z "$finding" ]] && continue
		local ftype ffile_a fexcerpt_a ffile_b fexcerpt_b
		ftype=$(printf '%s' "$finding" | jq -r '.type // "unknown"')
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
			# Known finding — update last_seen_at atomically, no bus event
			(( known_count++ )) || true
			if [[ -f "$finding_file" ]]; then
				local updated
				updated=$(jq --argjson ts "$now" '.last_seen_at=$ts' "$finding_file" 2>/dev/null) || true
				[[ -n "$updated" ]] && printf '%s\n' "$updated" >"${finding_file}.tmp" \
					&& mv -f "${finding_file}.tmp" "$finding_file"
			fi
		else
			# New finding — write file atomically, emit bus event, then mark dedup
			local with_ts
			with_ts=$(printf '%s' "$finding" \
				| jq --argjson ts "$now" '. + {"first_seen_at":$ts,"last_seen_at":$ts,"resolved":false}')
			printf '%s\n' "$with_ts" >"${finding_file}.tmp"
			mv -f "${finding_file}.tmp" "$finding_file"

			local ftype fseverity ffile_a ffile_b fdesc
			ftype=$(printf '%s' "$finding" | jq -r '.type // "unknown"')
			fseverity=$(printf '%s' "$finding" | jq -r '.severity // "warning"')
			ffile_a=$(printf '%s' "$finding" | jq -r '.file_a // ""')
			ffile_b=$(printf '%s' "$finding" | jq -r '.file_b // null')
			fdesc=$(printf '%s' "$finding" | jq -r '.description // ""')

			emit_safe "cartographer.issue.found" "$(jq -n \
				--arg audit_id "$AUDIT_ID" \
				--arg finding_hash "$fhash" \
				--arg finding_type "$ftype" \
				--arg severity "$fseverity" \
				--argjson affected_files "$(jq -n --arg a "$ffile_a" --arg b "$ffile_b" \
					'if $b == "null" or $b == "" then [$a] else [$a,$b] end')" \
				--arg summary "$fdesc" \
				'{"audit_id":$audit_id,"finding_hash":$finding_hash,"finding_type":$finding_type,"severity":$severity,"affected_files":$affected_files,"summary":$summary}')"

			touch "$dedup_sentinel"
			(( new_count++ )) || true
		fi
	done < <(printf '%s' "$ALL_FINDINGS" | jq -c '.[]' 2>/dev/null)

	log "phase=emit new=${new_count} known=${known_count}"

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
		--argjson total_finding_count "$total_count" \
		--argjson duration_ms "$duration_ms" \
		--argjson phases_completed "$(printf '%s\n' "${PHASES_COMPLETED[@]}" | jq -R . | jq -s .)" \
		--argjson phases_failed "$(printf '%s\n' "${PHASES_FAILED[@]:-}" | jq -R . | jq -s .)" \
		'{"audit_id":$audit_id,"trigger":$trigger,"new_finding_count":$new_finding_count,"known_finding_count":$known_finding_count,"total_finding_count":$total_finding_count,"duration_ms":$duration_ms,"phases_completed":$phases_completed,"phases_failed":$phases_failed}' \
		>"${run_file}.tmp" && mv -f "${run_file}.tmp" "$run_file"

	emit_safe "cartographer.audit.complete" "$(jq -n \
		--arg audit_id "$AUDIT_ID" \
		--arg trigger "$TRIGGER" \
		--argjson new_finding_count "$new_count" \
		--argjson total_finding_count "$total_count" \
		--argjson duration_ms "$duration_ms" \
		'{"audit_id":$audit_id,"trigger":$trigger,"new_finding_count":$new_finding_count,"total_finding_count":$total_finding_count,"duration_ms":$duration_ms}')"

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

	# Only advance last_audit_at if no phases failed (full completion)
	if [[ "${#PHASES_FAILED[@]}" -eq 0 ]]; then
		printf '%d' "$(date +%s)" >"$CARTOGRAPHER_DIR/last_audit_at"
		log "audit_id=${AUDIT_ID} completed successfully"
	else
		log "audit_id=${AUDIT_ID} partial — last_audit_at not advanced (failed: ${PHASES_FAILED[*]})"
	fi
}

main "$@"

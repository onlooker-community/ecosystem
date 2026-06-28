#!/usr/bin/env bash
# Librarian SessionEnd scan.
#
# Reads archivist artifacts created since the last librarian scan, runs them
# through the durability filter, classifies survivors via Haiku, and writes
# proposals to the queue for review at next SessionStart.
#
# Hook contract:
#   - Always exits 0. Never blocks session shutdown.
#   - No-ops when no project key (no git context) or no archivist artifacts.
#   - Classifier failures degrade gracefully: the affected candidate is
#     dropped, the rest of the scan proceeds.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Source the ecosystem substrate so $ONLOOKER_DIR / $ONLOOKER_EVENTS_LOG
# resolve correctly under the test harness's isolated temp home.
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
# shellcheck source=../lib/librarian-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
# shellcheck source=../lib/librarian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
# shellcheck source=../lib/librarian-emit.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
# shellcheck source=../lib/librarian-archivist-reader.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-archivist-reader.sh"
# shellcheck source=../lib/librarian-durability.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-durability.sh"
# shellcheck source=../lib/librarian-classifier.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-classifier.sh"

INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

librarian_config_load "$(librarian_project_repo_root "$CWD")"

PROJECT_KEY=$(librarian_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && exit 0

# Storage init + manifest refresh.
librarian_storage_init "$PROJECT_KEY" || exit 0
REMOTE_URL=$(librarian_project_remote_url "$CWD")
REPO_ROOT=$(librarian_project_repo_root "$CWD")
librarian_storage_write_manifest "$PROJECT_KEY" "$REMOTE_URL" "$REPO_ROOT" || true

# ----------------------------------------------------------------------------
# Determine the watermark. Empty means "first scan" — fall back to N days ago.
# ----------------------------------------------------------------------------

WATERMARK=$(librarian_storage_read_last_scan "$PROJECT_KEY")

if [[ -z "$WATERMARK" ]]; then
	BOOTSTRAP_DAYS=$(librarian_config_get '.librarian.scan.bootstrap_lookback_days')
	[[ -z "$BOOTSTRAP_DAYS" || "$BOOTSTRAP_DAYS" == "null" ]] && BOOTSTRAP_DAYS=14
	WATERMARK=$(python3 -c "
import datetime
delta = datetime.timedelta(days=${BOOTSTRAP_DAYS})
now = datetime.datetime.now(datetime.timezone.utc)
print((now - delta).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null) || WATERMARK=""
fi

# ----------------------------------------------------------------------------
# Emit scan.started and load candidate window.
# ----------------------------------------------------------------------------

SCAN_START_TS_S=$(date +%s)
ARTIFACTS=$(librarian_archivist_load_since "$PROJECT_KEY" "$WATERMARK")
ARTIFACT_COUNT=$(printf '%s' "$ARTIFACTS" | jq 'length' 2>/dev/null) || ARTIFACT_COUNT=0

librarian_emit "librarian.scan.started" "$SESSION_ID" "$(jq -cn \
	--arg trigger "session_end" \
	--arg last_scan_at "$WATERMARK" \
	--argjson artifact_count_in_window "$ARTIFACT_COUNT" \
	'{ trigger: $trigger, last_scan_at: (if $last_scan_at == "" then null else $last_scan_at end),
	   artifact_count_in_window: $artifact_count_in_window } | with_entries(select(.value != null))')"

# Bail with scan.complete{outcome: ok, candidates: 0} when archivist has
# nothing new for us. We still advance the watermark so subsequent scans
# don't re-walk the same window.
if [[ "$ARTIFACT_COUNT" == "0" ]]; then
	librarian_storage_write_last_scan "$PROJECT_KEY" || true
	DURATION_MS=$(( ($(date +%s) - SCAN_START_TS_S) * 1000 ))
	librarian_emit "librarian.scan.complete" "$SESSION_ID" "$(jq -cn \
		--arg outcome "empty" \
		--argjson duration_ms "$DURATION_MS" \
		--argjson candidates_proposed 0 \
		--argjson candidates_dropped 0 \
		--argjson artifact_count_in_window 0 \
		'{ outcome: $outcome, duration_ms: $duration_ms,
		   candidates_proposed: $candidates_proposed,
		   candidates_dropped: $candidates_dropped,
		   artifact_count_in_window: $artifact_count_in_window }')"
	exit 0
fi

# ----------------------------------------------------------------------------
# Durability filter — cheap, deterministic, no network.
# ----------------------------------------------------------------------------

MARKERS_JSON=$(librarian_config_get '.librarian.durability_filter.marker_phrases | tojson')
[[ -z "$MARKERS_JSON" || "$MARKERS_JSON" == "null" ]] && MARKERS_JSON='[]'
MIN_DETAIL=$(librarian_config_get '.librarian.scan.min_detail_chars')
[[ -z "$MIN_DETAIL" || "$MIN_DETAIL" == "null" ]] && MIN_DETAIL=40

FILTERED=$(librarian_durability_filter "$ARTIFACTS" "$MARKERS_JSON" "$MIN_DETAIL")
KEPT=$(printf '%s' "$FILTERED" | jq '.kept')
DROPPED=$(printf '%s' "$FILTERED" | jq '.dropped')

# Emit one librarian.candidate.dropped event per artifact we filtered out
# pre-classifier. Caps at a sane number per scan so the event log stays
# scannable even if archivist piled up months of artifacts.
MAX_DROPPED_EVENTS=20
DROPPED_TOTAL=$(printf '%s' "$DROPPED" | jq 'length' 2>/dev/null) || DROPPED_TOTAL=0
DROPPED_EMIT_COUNT=$(( DROPPED_TOTAL < MAX_DROPPED_EVENTS ? DROPPED_TOTAL : MAX_DROPPED_EVENTS ))
for ((i = 0; i < DROPPED_EMIT_COUNT; i++)); do
	DROP=$(printf '%s' "$DROPPED" | jq -c ".[$i]")
	librarian_emit "librarian.candidate.dropped" "$SESSION_ID" "$(jq -cn \
		--argjson drop "$DROP" \
		'{ reason: $drop.reason, source_artifact_id: $drop.artifact_id }
		 | with_entries(select(.value != null))')"
done

# ----------------------------------------------------------------------------
# Classifier loop — one Haiku call per surviving candidate.
# ----------------------------------------------------------------------------

CLASSIFIER_MODEL=$(librarian_config_get '.librarian.classifier.model')
CLASSIFIER_TEMP=$(librarian_config_get '.librarian.classifier.temperature')
CLASSIFIER_MAX=$(librarian_config_get '.librarian.classifier.max_output_tokens')
MIN_CONFIDENCE=$(librarian_config_get '.librarian.classifier.min_classifier_confidence')
[[ -z "$MIN_CONFIDENCE" || "$MIN_CONFIDENCE" == "null" ]] && MIN_CONFIDENCE="0.6"
TOMBSTONE_TTL=$(librarian_config_get '.librarian.tombstones.ttl_days')
[[ -z "$TOMBSTONE_TTL" || "$TOMBSTONE_TTL" == "null" ]] && TOMBSTONE_TTL=180
AUTO_PROMOTE_THRESHOLD=$(librarian_config_get '.librarian.auto_promote_threshold')
[[ -z "$AUTO_PROMOTE_THRESHOLD" || "$AUTO_PROMOTE_THRESHOLD" == "null" ]] && AUTO_PROMOTE_THRESHOLD="0.85"

KEPT_COUNT=$(printf '%s' "$KEPT" | jq 'length' 2>/dev/null) || KEPT_COUNT=0
PROPOSED_COUNT=0
POST_CLASSIFIER_DROPPED=0
NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

for ((i = 0; i < KEPT_COUNT; i++)); do
	ARTIFACT=$(printf '%s' "$KEPT" | jq -c ".[$i]")
	[[ -z "$ARTIFACT" || "$ARTIFACT" == "null" ]] && continue

	RESPONSE=$(librarian_classifier_call \
		"$ARTIFACT" "$CLASSIFIER_MODEL" "$CLASSIFIER_TEMP" "$CLASSIFIER_MAX")

	if [[ -z "$RESPONSE" ]]; then
		POST_CLASSIFIER_DROPPED=$((POST_CLASSIFIER_DROPPED + 1))
		librarian_emit "librarian.candidate.dropped" "$SESSION_ID" "$(jq -cn \
			--arg reason "classified_null" \
			--arg src "$(printf '%s' "$ARTIFACT" | jq -r '.id // ""')" \
			'{ reason: $reason, source_artifact_id: (if $src == "" then null else $src end) }
			 | with_entries(select(.value != null))')"
		continue
	fi

	# Drop nulls and low-confidence classifications silently — by design,
	# the proposal queue prefers misses over noise.
	MEMORY_TYPE=$(printf '%s' "$RESPONSE" | jq -r '.type // ""')
	CONFIDENCE=$(printf '%s' "$RESPONSE" | jq -r '.confidence // 0')
	BODY=$(printf '%s' "$RESPONSE" | jq -r '.body // ""')
	TITLE=$(printf '%s' "$RESPONSE" | jq -r '.title // ""')

	BELOW_MIN=$(awk -v a="$CONFIDENCE" -v b="$MIN_CONFIDENCE" 'BEGIN { print (a < b) ? 1 : 0 }')

	if [[ -z "$MEMORY_TYPE" || "$MEMORY_TYPE" == "null" ]]; then
		POST_CLASSIFIER_DROPPED=$((POST_CLASSIFIER_DROPPED + 1))
		librarian_emit "librarian.candidate.dropped" "$SESSION_ID" "$(jq -cn \
			--arg reason "classified_null" \
			--arg src "$(printf '%s' "$ARTIFACT" | jq -r '.id // ""')" \
			'{ reason: $reason, source_artifact_id: (if $src == "" then null else $src end) }
			 | with_entries(select(.value != null))')"
		continue
	fi

	if [[ "$BELOW_MIN" == "1" ]]; then
		POST_CLASSIFIER_DROPPED=$((POST_CLASSIFIER_DROPPED + 1))
		librarian_emit "librarian.candidate.dropped" "$SESSION_ID" "$(jq -cn \
			--arg reason "low_confidence" \
			--arg src "$(printf '%s' "$ARTIFACT" | jq -r '.id // ""')" \
			'{ reason: $reason, source_artifact_id: (if $src == "" then null else $src end) }
			 | with_entries(select(.value != null))')"
		continue
	fi

	# Skip if a tombstone exists for this exact body — the user already
	# rejected this content, don't re-surface it.
	BODY_HASH=$(librarian_body_hash "$BODY")
	if [[ -n "$BODY_HASH" ]] && librarian_storage_has_tombstone \
			"$PROJECT_KEY" "$BODY_HASH" "$TOMBSTONE_TTL"; then
		POST_CLASSIFIER_DROPPED=$((POST_CLASSIFIER_DROPPED + 1))
		librarian_emit "librarian.candidate.dropped" "$SESSION_ID" "$(jq -cn \
			--arg reason "duplicate" \
			--arg src "$(printf '%s' "$ARTIFACT" | jq -r '.id // ""')" \
			'{ reason: $reason, source_artifact_id: (if $src == "" then null else $src end) }
			 | with_entries(select(.value != null))')"
		continue
	fi

	# Build and persist the proposal. Conflict detection against the user's
	# memory store is deferred to a follow-up commit; everything ships as
	# conflict_state: "none" for now.
	PROPOSAL_ID=$(librarian_ulid)
	FILENAME=$(librarian_classifier_filename "$MEMORY_TYPE" "$TITLE")
	ARTIFACT_ID=$(printf '%s' "$ARTIFACT" | jq -r '.id // ""')
	ARTIFACT_SESSION=$(printf '%s' "$ARTIFACT" | jq -r '.session_id // ""')

	PROPOSAL_JSON=$(jq -n \
		--arg id "$PROPOSAL_ID" \
		--arg created_at "$NOW_TS" \
		--arg memory_type "$MEMORY_TYPE" \
		--arg filename "$FILENAME" \
		--arg title "$TITLE" \
		--arg body "$BODY" \
		--argjson classifier_confidence "$CONFIDENCE" \
		--arg conflict_state "none" \
		--arg artifact_id "$ARTIFACT_ID" \
		--arg artifact_session "$ARTIFACT_SESSION" \
		'{
			id: $id,
			created_at: $created_at,
			source_artifact_ids: (if $artifact_id == "" then [] else [$artifact_id] end),
			source_session_ids: (if $artifact_session == "" then [] else [$artifact_session] end),
			proposed: {
				type: $memory_type,
				filename: $filename,
				title: $title,
				body: $body,
				classifier_confidence: $classifier_confidence
			},
			conflict_state: $conflict_state,
			conflict_with: [],
			status: "pending"
		}')

	librarian_storage_write_proposal "$PROJECT_KEY" "$PROPOSAL_ID" "$PROPOSAL_JSON" >/dev/null \
		|| continue

	PROPOSED_COUNT=$((PROPOSED_COUNT + 1))

	# Write a flat artifact JSON for the artifact browser. The proposal file
	# uses a nested `proposed.*` structure; this flat copy matches the web's
	# LibrarianContent type so the dashboard can render it directly.
	ARTIFACT_CONTENT=$(jq -n \
		--arg type "$MEMORY_TYPE" \
		--arg title "$TITLE" \
		--arg body "$BODY" \
		--argjson classifier_confidence "$CONFIDENCE" \
		--arg conflict_state "none" \
		--argjson source_session_ids \
			"$(if [[ -n "$ARTIFACT_SESSION" ]]; then
				printf '["%s"]' "$ARTIFACT_SESSION"
			else
				printf '[]'
			fi)" \
		'{type: $type, title: $title, body: $body,
		  classifier_confidence: $classifier_confidence,
		  conflict_state: $conflict_state,
		  source_session_ids: $source_session_ids}') || ARTIFACT_CONTENT=""

	if [[ -n "$ARTIFACT_CONTENT" ]]; then
		ARTIFACTS_DIR="$(librarian_project_dir "$PROJECT_KEY")/artifacts"
		mkdir -p "$ARTIFACTS_DIR" 2>/dev/null || true
		ARTIFACT_PATH="${ARTIFACTS_DIR}/${PROPOSAL_ID}.json"
		printf '%s\n' "$ARTIFACT_CONTENT" > "$ARTIFACT_PATH" 2>/dev/null || ARTIFACT_PATH=""
	fi

	if [[ -n "${ARTIFACT_PATH:-}" ]]; then
		librarian_emit "onlooker.artifact.ready" "$SESSION_ID" "$(jq -cn \
			--arg plugin "librarian" \
			--arg artifact_kind "proposal" \
			--arg artifact_path "$ARTIFACT_PATH" \
			--arg artifact_title "$TITLE" \
			'{plugin: $plugin, artifact_kind: $artifact_kind,
			  artifact_path: $artifact_path, artifact_title: $artifact_title}')"
	fi

	librarian_emit "librarian.candidate.proposed" "$SESSION_ID" "$(jq -cn \
		--arg proposal_id "$PROPOSAL_ID" \
		--arg memory_type "$MEMORY_TYPE" \
		--argjson classifier_confidence "$CONFIDENCE" \
		--arg conflict_state "none" \
		--arg src "$ARTIFACT_ID" \
		'{
			proposal_id: $proposal_id,
			memory_type: $memory_type,
			classifier_confidence: $classifier_confidence,
			conflict_state: $conflict_state,
			source_artifact_ids: (if $src == "" then [] else [$src] end)
		}')"
done

# ----------------------------------------------------------------------------
# Watermark advance + scan.complete.
# ----------------------------------------------------------------------------

librarian_storage_write_last_scan "$PROJECT_KEY" || true

TOTAL_DROPPED=$((DROPPED_TOTAL + POST_CLASSIFIER_DROPPED))
OUTCOME="ok"
[[ "$PROPOSED_COUNT" == "0" ]] && OUTCOME="empty"
DURATION_MS=$(( ($(date +%s) - SCAN_START_TS_S) * 1000 ))

librarian_emit "librarian.scan.complete" "$SESSION_ID" "$(jq -cn \
	--arg outcome "$OUTCOME" \
	--argjson candidates_proposed "$PROPOSED_COUNT" \
	--argjson candidates_dropped "$TOTAL_DROPPED" \
	--argjson duration_ms "$DURATION_MS" \
	--argjson artifact_count_in_window "$ARTIFACT_COUNT" \
	'{
		outcome: $outcome,
		candidates_proposed: $candidates_proposed,
		candidates_dropped: $candidates_dropped,
		duration_ms: $duration_ms,
		artifact_count_in_window: $artifact_count_in_window
	}')"

# Suppress AUTO_PROMOTE_THRESHOLD shellcheck warning — read for future use
# (auto-promote path lands in the next commit).
: "${AUTO_PROMOTE_THRESHOLD}"

exit 0

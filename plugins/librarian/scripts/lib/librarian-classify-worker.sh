#!/usr/bin/env bash
# Librarian's classifier, run detached and off the SessionEnd clock.
#
# WHY THIS IS NOT IN THE HOOK (ecosystem-449.72). A hook resolves
# /opt/homebrew/bin/claude, and against that binary one classifier call put its
# answer on stdout at +39,065ms and exited at +46,484ms. A trivial prompt cost
# ~29,000ms, so most of that is nested CLI session startup rather than model
# work (ecosystem-449.73). SessionEnd's ceiling is 1500ms and a plugin cannot
# raise it, so a single call is ~26x the entire budget. Capping calls to the
# remaining budget cannot fit even one, and a timeout inside the remaining
# budget would fire on every call -- both were considered and are arithmetically
# impossible, not merely tight.
#
# The shipped per-call timeout was 20s, BELOW the ~39s a call needs, so every
# call was killed before its answer arrived and recorded as classified_null.
# That is why librarian.candidate.proposed is 0 all-time (ecosystem-449.67).
# Raising the timeout and moving the work had to land together: at 20s nothing
# ever returns, and a longer timeout inside SessionEnd would block it for
# minutes.
#
# Contract:
#   - Invoked as: librarian-classify-worker.sh <queue-file>
#   - Detached by the hook; nothing waits on it and no budget applies.
#   - Emits librarian.scan.complete itself. SessionEnd deliberately does not,
#     because the outcome enum is ok|empty|skipped|budget_exceeded with
#     additionalProperties:false and none of them means "queued for a worker".
#     Inventing one would be a schema change; reporting the real outcome when it
#     lands is free and truthful. Same shape as plugin-currency-surfacer, whose
#     detached probe emits onlooker.currency.checked itself.
#   - Removes the queue file only on success, so a worker that dies leaves its
#     input on disk to be retried. That is what makes advancing the watermark in
#     SessionEnd safe, and why this does not depend on ecosystem-449.55.
#   - Always exits 0. A failed classification is a dropped candidate, not an
#     error anyone is waiting to see.

set -uo pipefail

# Recursion guard. The worker reaches claude, that nested session ends and fires
# SessionEnd, which re-enters the hook -- which would queue and spawn again.
[[ "${LIBRARIAN_NESTED:-}" == "1" ]] && exit 0
export LIBRARIAN_NESTED=1

QUEUE_FILE="${1:-}"
[[ -n "$QUEUE_FILE" && -f "$QUEUE_FILE" ]] || exit 0

# ../.. not ..: this file lives in scripts/lib, so one level up is scripts, and
# rooting there makes every source below resolve to scripts/scripts/lib/... The
# hook next door needs ../.. from scripts/hooks for the same reason. Getting
# this wrong fails silently — without errexit the sources just print to stderr
# and the script runs on with every accessor undefined, then exits 0 reporting
# nothing, which is the shape ecosystem-ber and 449.36 both describe.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Ecosystem substrate, resolved the shared way rather than with a hand-rolled
# glob (ecosystem-449.36, ecosystem-449.35).
# shellcheck source=substrate-resolve.sh
source "${PLUGIN_ROOT}/scripts/lib/substrate-resolve.sh"
_ECOSYSTEM_ROOT=$(onlooker_resolve_substrate "$PLUGIN_ROOT")
if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	CLAUDE_PLUGIN_ROOT="$_ECOSYSTEM_ROOT" source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
fi

# shellcheck source=librarian-config.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-config.sh"
# shellcheck source=librarian-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-project-key.sh"
# shellcheck source=librarian-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-ulid.sh"
# shellcheck source=librarian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-storage.sh"
# shellcheck source=librarian-emit.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-emit.sh"
# shellcheck source=librarian-durability.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-durability.sh"
# shellcheck source=librarian-classifier.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-classifier.sh"
# shellcheck source=librarian-conflict-detector.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-conflict-detector.sh"
# shellcheck source=librarian-lesson-validate.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-validate.sh"
# shellcheck source=librarian-lesson-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-storage.sh"
# shellcheck source=librarian-lesson-transform.sh
source "${PLUGIN_ROOT}/scripts/lib/librarian-lesson-transform.sh"

# The sources above cannot fail loudly: this runs without errexit, so a bad
# PLUGIN_ROOT leaves every function undefined and the script still exits 0 —
# indistinguishable from "there was nothing to classify". One probe per lib
# family turns that into a single explicit line in the log instead.
for _fn in librarian_config_load librarian_storage_init librarian_emit \
	librarian_classifier_call; do
	if ! declare -F "$_fn" >/dev/null 2>&1; then
		printf 'librarian-classify-worker: %s undefined after sourcing from %s\n' \
			"$_fn" "$PLUGIN_ROOT" >&2
		exit 0
	fi
done
unset _fn

librarian_now_ms() {
	local now_ms
	now_ms=$(python3 - <<'PY' 2>/dev/null
import time
print(int(time.time() * 1000))
PY
	) || now_ms=""
	[[ -z "$now_ms" ]] && now_ms=$(( $(date +%s) * 1000 ))
	printf '%s' "$now_ms"
}

# One worker per queue file. mkdir is the atomic test-and-set, the same
# mechanism plugin-currency-surfacer's _spawn_refresh uses. Declining is not a
# failure: the run already in flight owns this window.
QUEUE_LOCK="${QUEUE_FILE}.lock"
mkdir "$QUEUE_LOCK" 2>/dev/null || exit 0
trap 'rmdir "$QUEUE_LOCK" 2>/dev/null || true' EXIT

# Restore what SessionEnd established before the handoff. Anything read here
# that the queue does not carry would silently be empty, so the writer and this
# block are a matched pair — see _write_classify_queue in the hook.
CWD=$(jq -r '.cwd // ""' "$QUEUE_FILE" 2>/dev/null) || CWD=""
SESSION_ID=$(jq -r '.session_id // "unknown"' "$QUEUE_FILE" 2>/dev/null) || SESSION_ID="unknown"
PROJECT_KEY=$(jq -r '.project_key // ""' "$QUEUE_FILE" 2>/dev/null) || PROJECT_KEY=""
ARTIFACT_COUNT=$(jq -r '.artifact_count_in_window // 0' "$QUEUE_FILE" 2>/dev/null) || ARTIFACT_COUNT=0
DROPPED_TOTAL=$(jq -r '.candidates_dropped // 0' "$QUEUE_FILE" 2>/dev/null) || DROPPED_TOTAL=0
KEPT=$(jq -c '.artifacts // []' "$QUEUE_FILE" 2>/dev/null) || KEPT="[]"

# duration_ms on scan.complete now measures the WHOLE scan, hook plus worker,
# because that is what the scan actually took. It used to be a sub-1500ms
# number, so a consumer comparing across this change will see it jump by orders
# of magnitude. Per-hook cost is hook-health's job (ecosystem-449.66), not this
# field's.
SCAN_START_TS_MS=$(jq -r '.queued_at_ms // 0' "$QUEUE_FILE" 2>/dev/null) || SCAN_START_TS_MS=0
[[ "$SCAN_START_TS_MS" =~ ^[0-9]+$ ]] || SCAN_START_TS_MS=$(librarian_now_ms)
[[ "$SCAN_START_TS_MS" == "0" ]] && SCAN_START_TS_MS=$(librarian_now_ms)

[[ -z "$CWD" ]] && exit 0
[[ -z "$PROJECT_KEY" ]] && exit 0

librarian_config_load "$CWD"
librarian_storage_init "$PROJECT_KEY" || exit 0
REMOTE_URL=$(librarian_project_remote_url "$CWD")
REPO_ROOT=$(librarian_project_repo_root "$CWD")

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

	# Build and persist the proposal. Detect conflicts against the user's
	# memory store before writing.
	PROPOSAL_ID=$(librarian_ulid)
	FILENAME=$(librarian_classifier_filename "$MEMORY_TYPE" "$TITLE")
	ARTIFACT_ID=$(printf '%s' "$ARTIFACT" | jq -r '.id // ""')
	ARTIFACT_SESSION=$(printf '%s' "$ARTIFACT" | jq -r '.session_id // ""')

	# Resolve the typed memory store path for this project.
	MEMORY_STORE_PATH=$(librarian_config_get '.librarian.memory_store_path')
	[[ -z "$MEMORY_STORE_PATH" || "$MEMORY_STORE_PATH" == "null" ]] && \
		MEMORY_STORE_PATH='${CLAUDE_CONFIG_DIR}/projects/${CLAUDE_PROJECT_ENCODED}/memory'

	# Interpolate placeholders. This was `eval echo`, which command-substituted
	# a value the config loader reads from <repo>/.claude/settings.json — so a
	# cloned repo could run anything here, as the user, on every SessionEnd
	# (ecosystem-18f).
	MEMORY_STORE_PATH=$(librarian_memory_resolve_path "$MEMORY_STORE_PATH")

	# Initialize conflict state; will scan if memory dir exists.
	CONFLICT_STATE="none"
	CONFLICT_WITH="[]"

	# Detect conflicts against existing memories only if the directory exists.
	if [[ -d "$MEMORY_STORE_PATH" ]]; then
		# Build a temporary proposal for conflict detection.
		TEMP_PROPOSAL=$(jq -n \
			--arg id "$PROPOSAL_ID" \
			--arg memory_type "$MEMORY_TYPE" \
			--arg filename "$FILENAME" \
			--arg title "$TITLE" \
			--arg body "$BODY" \
			--argjson classifier_confidence "$CONFIDENCE" \
			'{
				id: $id,
				proposed: {
					type: $memory_type,
					filename: $filename,
					title: $title,
					body: $body,
					classifier_confidence: $classifier_confidence
				}
			}')

		# Detect conflicts against existing memories.
		DUP_THRESHOLD=$(librarian_config_get '.librarian.conflict.duplicate_threshold')
		[[ -z "$DUP_THRESHOLD" || "$DUP_THRESHOLD" == "null" ]] && DUP_THRESHOLD="0.7"
		MERGE_THRESHOLD=$(librarian_config_get '.librarian.conflict.merge_candidate_threshold')
		[[ -z "$MERGE_THRESHOLD" || "$MERGE_THRESHOLD" == "null" ]] && MERGE_THRESHOLD="0.45"

		CONFLICT_RESULT=$(librarian_conflict_scan "$TEMP_PROPOSAL" "$MEMORY_STORE_PATH" \
			"$DUP_THRESHOLD" "$MERGE_THRESHOLD" 2>/dev/null) || CONFLICT_RESULT=""

		# Ensure we have valid JSON; fall back to "none" if scan fails.
		if [[ -z "$CONFLICT_RESULT" ]] || ! printf '%s' "$CONFLICT_RESULT" | jq -e '.' >/dev/null 2>&1; then
			CONFLICT_RESULT='{"conflict_state":"none","conflict_with":[]}'
		fi

		CONFLICT_STATE=$(printf '%s' "$CONFLICT_RESULT" | jq -r '.conflict_state // "none"' 2>/dev/null) || CONFLICT_STATE="none"
		CONFLICT_WITH=$(printf '%s' "$CONFLICT_RESULT" | jq -c '.conflict_with // []' 2>/dev/null) || CONFLICT_WITH="[]"

		# Silently drop duplicates — no proposal written.
		if [[ "$CONFLICT_STATE" == "duplicate" ]]; then
			POST_CLASSIFIER_DROPPED=$((POST_CLASSIFIER_DROPPED + 1))
			librarian_emit "librarian.candidate.dropped" "$SESSION_ID" "$(jq -cn \
				--arg reason "duplicate" \
				--arg src "$ARTIFACT_ID" \
				'{ reason: $reason, source_artifact_id: (if $src == "" then null else $src end) }
				 | with_entries(select(.value != null))')"
			continue
		fi
	fi

	PROPOSAL_JSON=$(jq -n \
		--arg id "$PROPOSAL_ID" \
		--arg created_at "$NOW_TS" \
		--arg memory_type "$MEMORY_TYPE" \
		--arg filename "$FILENAME" \
		--arg title "$TITLE" \
		--arg body "$BODY" \
		--argjson classifier_confidence "$CONFIDENCE" \
		--arg conflict_state "$CONFLICT_STATE" \
		--argjson conflict_with "$CONFLICT_WITH" \
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
			conflict_with: $conflict_with,
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
		--arg conflict_state "$CONFLICT_STATE" \
		--arg src "$ARTIFACT_ID" \
		'{
			proposal_id: $proposal_id,
			memory_type: $memory_type,
			classifier_confidence: $classifier_confidence,
			conflict_state: $conflict_state,
			source_artifact_ids: (if $src == "" then [] else [$src] end)
		}')"
done

# ---------------------------------------------------------------------------
# Stage 5 — lesson transform.
#
# Runs over the same durability survivors the classifier saw. Each artifact is
# independent: a decline or an outage on one never stops the rest.
#
# Budgeted in aggregate, not just per call. Each transform carries a 20s
# ceiling of its own, but nothing bounded KEPT_COUNT of them end to end, so a
# backlog could hold SessionEnd open for minutes (ecosystem-qwi). The check is
# per iteration rather than once before the loop: a pre-loop gate only decides
# whether to start, and once started the cost is still unbounded — which is the
# gap the classifier loop above still has.
#
# Skipping is the safe direction. Untransformed artifacts are reconsidered on a
# later session, so the cost of stopping early is a delay; the cost of not
# stopping is a session that will not close.
# ---------------------------------------------------------------------------
LESSON_PROPOSED=0
LESSON_DECLINED=0
LESSONS_SKIPPED=0

LESSON_BUDGET_MS=$(librarian_config_get '.librarian.lesson_transform.total_budget_ms' 2>/dev/null)
[[ -z "$LESSON_BUDGET_MS" || "$LESSON_BUDGET_MS" == "null" ]] && LESSON_BUDGET_MS=600000
LESSON_START_MS=$(librarian_now_ms)

for ((li = 0; li < KEPT_COUNT; li++)); do
	if [[ $(( $(librarian_now_ms) - LESSON_START_MS )) -ge "$LESSON_BUDGET_MS" ]]; then
		LESSONS_SKIPPED=$(( KEPT_COUNT - li ))
		break
	fi

	LESSON_ARTIFACT=$(printf '%s' "$KEPT" | jq -c ".[$li]")
	[[ -z "$LESSON_ARTIFACT" || "$LESSON_ARTIFACT" == "null" ]] && continue

	LESSON_RESULT=$(librarian_lesson_transform_one "$PROJECT_KEY" "$LESSON_ARTIFACT")
	case "$LESSON_RESULT" in
		proposed:*) LESSON_PROPOSED=$((LESSON_PROPOSED + 1)) ;;
		declined:*) LESSON_DECLINED=$((LESSON_DECLINED + 1)) ;;
	esac
done

# LESSONS_SKIPPED rides on scan.complete below rather than becoming an event of
# its own. A truncated stage 5 is not a truncated scan: the scan finishes
# normally and only this stage stops early, so the count belongs beside a
# healthy outcome rather than replacing it.

# ----------------------------------------------------------------------------
# Watermark advance + scan.complete.
# ----------------------------------------------------------------------------

librarian_storage_write_last_scan "$PROJECT_KEY" || true

TOTAL_DROPPED=$((DROPPED_TOTAL + POST_CLASSIFIER_DROPPED))
OUTCOME="ok"
[[ "$PROPOSED_COUNT" == "0" ]] && OUTCOME="empty"
DURATION_MS=$(( $(librarian_now_ms) - SCAN_START_TS_MS ))

librarian_emit "librarian.scan.complete" "$SESSION_ID" "$(jq -cn \
	--arg outcome "$OUTCOME" \
	--argjson candidates_proposed "$PROPOSED_COUNT" \
	--argjson candidates_dropped "$TOTAL_DROPPED" \
	--argjson lessons_skipped "$LESSONS_SKIPPED" \
	--argjson duration_ms "$DURATION_MS" \
	--argjson artifact_count_in_window "$ARTIFACT_COUNT" \
	'{
		outcome: $outcome,
		candidates_proposed: $candidates_proposed,
		candidates_dropped: $candidates_dropped,
		lessons_skipped: $lessons_skipped,
		duration_ms: $duration_ms,
		artifact_count_in_window: $artifact_count_in_window
	}')"

# Suppress AUTO_PROMOTE_THRESHOLD shellcheck warning — read for future use
# (auto-promote path lands in the next commit).
: "${AUTO_PROMOTE_THRESHOLD}"

# The window is accounted for, so the queue file has done its job. Removing it
# HERE and nowhere earlier is the whole retry story: every path that gives up
# before this point leaves the file on disk, which is what lets SessionEnd
# advance the watermark without risking the loss ecosystem-449.55 describes.
rm -f "$QUEUE_FILE" 2>/dev/null || true

exit 0

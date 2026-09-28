#!/usr/bin/env bash
# run-index.sh — Historian's session indexing, off the SessionEnd path.
#
# Intended to run as a detached background process launched by the SessionEnd
# hook. historian-session-end.sh used to run the whole pipeline inline, and
# could not finish it. SessionEnd hooks that declare no timeout get a 1500ms
# abort window, and the work does not fit:
#
#   - A warm embed of one chunk measured 51ms, so the budget buys about 29
#     chunks before anything else is counted. A real 8.5MB transcript chunks
#     into 117.
#   - A COLD embed cannot happen at all. Loading nomic-embed-text measured
#     11.24s against a configured 8s request timeout, and the hook would be
#     killed at 1500ms long before either expired.
#
# Both failures were invisible. Every historian.indexing.complete with
# outcome "ok" in the live log indexed exactly 2 chunks, which is not
# historian working — it is the only size that fit. Larger sessions show up in
# hook-health.jsonl as `terminated` at 1503-1527ms (ONL-123).
#
# Detached, none of that is a constraint: the pass can take its 11.2s cold
# load and its 117 embeds, and the user's session closes immediately.
#
# Environment (all set by the launching hook):
#   HISTORIAN_SESSION_ID  — session whose transcript to index
#   HISTORIAN_CWD         — session cwd, for config and project key resolution
#   HISTORIAN_TRANSCRIPT  — transcript path, as the hook received it
#   CLAUDE_PLUGIN_ROOT    — plugin root
#   ONLOOKER_DIR          — state root, inherited so the child writes where the
#                           parent would have
#
# THIS SCRIPT HOLDS ITS OWN LOCK, and the launching hook must not take it
# (ecosystem-hap). portable-lock stamps the holder pid at acquire time; a
# launcher that acquires and exits within milliseconds leaves a holder that is
# already gone, so the next caller's `kill -0` calls the lock stale and
# reclaims it — a lock that excludes nothing.

set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# shellcheck source=./lib/substrate-resolve.sh
source "${PLUGIN_ROOT}/scripts/lib/substrate-resolve.sh"
_ECOSYSTEM_ROOT=$(onlooker_resolve_substrate "$PLUGIN_ROOT")
if [[ -n "$_ECOSYSTEM_ROOT" && -f "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh" ]]; then
	# shellcheck disable=SC1091
	export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"
	source "${_ECOSYSTEM_ROOT}/scripts/lib/validate-path.sh"
fi

# shellcheck source=./lib/portable-lock.sh
source "${PLUGIN_ROOT}/scripts/lib/portable-lock.sh"
# shellcheck source=./lib/historian-config.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-config.sh"
# shellcheck source=./lib/historian-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-project-key.sh"
# shellcheck source=./lib/historian-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-ulid.sh"
# shellcheck source=./lib/historian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-storage.sh"
# shellcheck source=./lib/historian-emit.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-emit.sh"
# shellcheck source=./lib/historian-transcript.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-transcript.sh"
# shellcheck source=./lib/historian-chunker.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-chunker.sh"
# shellcheck source=./lib/historian-sanitizer.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-sanitizer.sh"
# shellcheck source=./lib/historian-embedder.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-embedder.sh"

SESSION_ID="${HISTORIAN_SESSION_ID:-}"
CWD="${HISTORIAN_CWD:-}"
TRANSCRIPT_PATH="${HISTORIAN_TRANSCRIPT:-}"

[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"
[[ -z "$CWD" ]] && CWD="$(pwd)"

ONLOOKER_DIR="${ONLOOKER_DIR:-${HOME}/.onlooker}"

SCAN_START_MS=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) \
	|| SCAN_START_MS=$(($(date +%s) * 1000))

_now_ms() {
	python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null \
		|| printf '%s' "$(($(date +%s) * 1000))"
}

_emit_skip() {
	local reason="$1"
	local now_ms duration_ms
	now_ms=$(_now_ms)
	duration_ms=$((now_ms - SCAN_START_MS))
	historian_emit "historian.indexing.complete" "$SESSION_ID" "$(jq -cn \
		--arg outcome "skipped" \
		--arg skip_reason "$reason" \
		--argjson duration_ms "$duration_ms" \
		'{ outcome: $outcome, skip_reason: $skip_reason, duration_ms: $duration_ms }')"
}

historian_config_load "$CWD"
REPO_ROOT=$(historian_project_repo_root "$CWD")

PROJECT_KEY=$(historian_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && exit 0

historian_storage_init "$PROJECT_KEY" || exit 0
REMOTE_URL=$(historian_project_remote_url "$CWD")
historian_storage_write_manifest "$PROJECT_KEY" "$REMOTE_URL" "$REPO_ROOT" || true

# Keyed by session, not by project: two sessions indexing at once write
# different files and must not block each other, while two SessionEnd fires for
# the SAME session are the collision this prevents. Non-blocking, since a
# second pass would only redo what the holder is already doing.
LOCK_FILE="${ONLOOKER_DIR}/historian/sessions/${SESSION_ID}.index.lock"
mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
if ! lock_acquire "$LOCK_FILE" 0 0; then
	exit 0
fi
trap 'lock_release "$LOCK_FILE"' EXIT

# These two used to share one reason, transcript_unavailable, and that merge
# is why 2881 of historian's 4611 skips could not be acted on: a payload that
# carried no transcript_path is a hook-contract problem, while a path that was
# supplied with no file at it is a timing or lifetime problem, and the log said
# only that one of them happened (ONL-121).
if [[ -z "$TRANSCRIPT_PATH" ]]; then
	_emit_skip "transcript_path_absent"
	exit 0
fi

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
	_emit_skip "transcript_file_missing"
	exit 0
fi

MIN_CHARS=$(historian_config_get '.historian.indexing.min_transcript_chars_to_index')
[[ -z "$MIN_CHARS" || "$MIN_CHARS" == "null" ]] && MIN_CHARS=1200

TURNS=$(historian_transcript_load "$TRANSCRIPT_PATH")
TRANSCRIPT_CHARS=$(historian_transcript_char_count "$TURNS")
[[ -z "$TRANSCRIPT_CHARS" || "$TRANSCRIPT_CHARS" == "null" ]] && TRANSCRIPT_CHARS=0

historian_emit "historian.indexing.started" "$SESSION_ID" "$(jq -cn \
	--arg session_id "$SESSION_ID" \
	--argjson transcript_chars "$TRANSCRIPT_CHARS" \
	'{ session_id: $session_id, transcript_chars: $transcript_chars }')"

if (( TRANSCRIPT_CHARS < MIN_CHARS )); then
	_emit_skip "too_short"
	exit 0
fi

# ----------------------------------------------------------------------------
# Chunker → sanitizer → JSONL store.
# ----------------------------------------------------------------------------

TARGET_CHARS=$(historian_config_get '.historian.indexing.chunk_target_chars')
[[ -z "$TARGET_CHARS" || "$TARGET_CHARS" == "null" ]] && TARGET_CHARS=2400
OVERLAP_CHARS=$(historian_config_get '.historian.indexing.chunk_overlap_chars')
[[ -z "$OVERLAP_CHARS" || "$OVERLAP_CHARS" == "null" ]] && OVERLAP_CHARS=400

CHUNKS=$(historian_chunker_split "$TURNS" "$TARGET_CHARS" "$OVERLAP_CHARS")
NEVER_INDEX_PATHS=$(historian_config_get '.historian.sanitization.never_index_paths | tojson')
[[ -z "$NEVER_INDEX_PATHS" || "$NEVER_INDEX_PATHS" == "null" ]] && NEVER_INDEX_PATHS='[]'

REDACT_SECRETS=$(historian_config_get '.historian.sanitization.redact_secret_patterns')
[[ -z "$REDACT_SECRETS" || "$REDACT_SECRETS" == "null" ]] && REDACT_SECRETS="true"
DROP_SKIP=$(historian_config_get '.historian.sanitization.drop_skip_marker')
[[ -z "$DROP_SKIP" || "$DROP_SKIP" == "null" ]] && DROP_SKIP="true"

SANITIZED=$(historian_sanitizer_run "$CHUNKS" "$NEVER_INDEX_PATHS" "$REDACT_SECRETS" "$DROP_SKIP")
KEPT=$(printf '%s' "$SANITIZED" | jq '.kept')
DROPPED=$(printf '%s' "$SANITIZED" | jq '.dropped')

# Probe the embedder once before the chunk loop. A pass here means "worth
# trying", not "will work": the probe hits /api/tags, which answers instantly
# whether or not the model is resident, so a cold daemon passes and then times
# out on every embed. That is why the loop reports its own failures rather than
# trusting this.
EMBEDDER_READY=0
EMBEDDER_BACKEND=$(historian_config_get '.historian.embedder.backend')
[[ -z "$EMBEDDER_BACKEND" || "$EMBEDDER_BACKEND" == "null" ]] && EMBEDDER_BACKEND="none"
if [[ "$EMBEDDER_BACKEND" != "none" ]]; then
	if historian_embedder_available; then
		EMBEDDER_READY=1
	else
		historian_emit "historian.embedder.unavailable" "$SESSION_ID" "$(jq -cn \
			--arg backend "$EMBEDDER_BACKEND" \
			'{ backend: $backend }')"
	fi
fi

# Re-indexing replaces the existing session file rather than appending,
# so SessionEnd is safely idempotent if re-fired against the same id.
historian_storage_reset_session "$PROJECT_KEY" "$SESSION_ID"

NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CHUNKS_INDEXED=0
CHUNKS_EMBEDDED=0
CHUNKS_UNEMBEDDED=0
EMBED_ATTEMPTED=0
EMBED_FAILED=0
EMBED_FAIL_REASONS=""
EMBED_FAIL_DETAIL=""

while IFS= read -r CHUNK; do
	[[ -z "$CHUNK" || "$CHUNK" == "null" ]] && continue

	CHUNK_ID=$(historian_ulid)
	REDACTION_COUNT=$(printf '%s' "$CHUNK" | jq -r '.redaction_count // 0')
	BODY=$(printf '%s' "$CHUNK" | jq -r '.body_redacted // ""')

	RECORD=$(jq -cn \
		--arg chunk_id "$CHUNK_ID" \
		--arg session_id "$SESSION_ID" \
		--argjson chunk_input "$CHUNK" \
		--arg created_at "$NOW_TS" \
		--arg source "local" \
		'$chunk_input + {
			chunk_id: $chunk_id,
			session_id: $session_id,
			created_at: $created_at,
			source: $source
		}')

	if (( EMBEDDER_READY == 1 )) && [[ -n "$BODY" ]]; then
		historian_embedder_parse "$(historian_embedder_embed_reported "$BODY")"
		if [[ -n "$HISTORIAN_EMBEDDER_VECTOR" ]]; then
			RECORD=$(printf '%s' "$RECORD" | jq -c \
				--argjson v "$HISTORIAN_EMBEDDER_VECTOR" '. + { embedding: $v }')
			CHUNKS_EMBEDDED=$((CHUNKS_EMBEDDED + 1))
			EMBED_ATTEMPTED=$((EMBED_ATTEMPTED + 1))
		else
			CHUNKS_UNEMBEDDED=$((CHUNKS_UNEMBEDDED + 1))
			# An empty reason means nothing was attempted (backend off, empty
			# body), which is not a failure and must not be counted as one.
			if [[ -n "$HISTORIAN_EMBEDDER_REASON" ]]; then
				EMBED_ATTEMPTED=$((EMBED_ATTEMPTED + 1))
				EMBED_FAILED=$((EMBED_FAILED + 1))
				EMBED_FAIL_REASONS="${EMBED_FAIL_REASONS}${HISTORIAN_EMBEDDER_REASON}
"
				[[ -z "$EMBED_FAIL_DETAIL" ]] && EMBED_FAIL_DETAIL="$HISTORIAN_EMBEDDER_DETAIL"
			fi
		fi
	else
		CHUNKS_UNEMBEDDED=$((CHUNKS_UNEMBEDDED + 1))
	fi

	if historian_storage_append_chunk "$PROJECT_KEY" "$SESSION_ID" "$RECORD"; then
		CHUNKS_INDEXED=$((CHUNKS_INDEXED + 1))
		if (( REDACTION_COUNT > 0 )); then
			historian_emit "historian.chunk.sanitized" "$SESSION_ID" "$(jq -cn \
				--arg chunk_id "$CHUNK_ID" \
				--argjson redaction_count "$REDACTION_COUNT" \
				'{ chunk_id: $chunk_id, redaction_count: $redaction_count }')"
		fi
	fi
done < <(printf '%s' "$KEPT" | jq -c '.[]' 2>/dev/null)

# One aggregated failure event, not one per chunk: a 117-chunk session with a
# cold embedder would otherwise write 117 identical lines saying the same
# thing. The reason reported is the most common across the run.
if (( EMBED_FAILED > 0 )); then
	TOP_REASON=$(printf '%s' "$EMBED_FAIL_REASONS" \
		| grep -v '^[[:space:]]*$' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
	[[ -z "$TOP_REASON" ]] && TOP_REASON="request_failed"
	historian_emit "historian.embedder.failed" "$SESSION_ID" "$(jq -cn \
		--arg backend "$EMBEDDER_BACKEND" \
		--arg reason "$TOP_REASON" \
		--argjson attempted "$EMBED_ATTEMPTED" \
		--argjson failed "$EMBED_FAILED" \
		--arg error_summary "$EMBED_FAIL_DETAIL" \
		'{ backend: $backend, reason: $reason, attempted: $attempted, failed: $failed }
		 + (if $error_summary == "" then {} else { error_summary: $error_summary } end)')"

	# A timeout means the model was almost certainly cold. Start loading it now
	# so the NEXT session finds it resident — nothing here waits on it.
	if [[ "$TOP_REASON" == "timeout" ]]; then
		historian_embedder_warm
	fi
fi

# Emit one chunk.dropped event per skip reason summary (caps at the
# number of unique reasons; per-chunk emission would spam the log).
DROPPED_COUNT=$(printf '%s' "$DROPPED" | jq 'length' 2>/dev/null) || DROPPED_COUNT=0
if (( DROPPED_COUNT > 0 )); then
	for reason in $(printf '%s' "$DROPPED" | jq -r '.[].reason' | sort -u); do
		historian_emit "historian.chunk.dropped" "$SESSION_ID" "$(jq -cn \
			--arg reason "$reason" \
			'{ reason: $reason }')"
	done
fi

NOW_MS=$(_now_ms)
DURATION_MS=$((NOW_MS - SCAN_START_MS))

historian_emit "historian.indexing.complete" "$SESSION_ID" "$(jq -cn \
	--arg outcome "ok" \
	--argjson chunks_indexed "$CHUNKS_INDEXED" \
	--argjson chunks_dropped "$DROPPED_COUNT" \
	--argjson chunks_embedded "$CHUNKS_EMBEDDED" \
	--argjson chunks_unembedded "$CHUNKS_UNEMBEDDED" \
	--argjson duration_ms "$DURATION_MS" \
	'{
		outcome: $outcome,
		chunks_indexed: $chunks_indexed,
		chunks_dropped: $chunks_dropped,
		chunks_embedded: $chunks_embedded,
		chunks_unembedded: $chunks_unembedded,
		duration_ms: $duration_ms
	}')"

exit 0

#!/usr/bin/env bash
# Historian SessionEnd indexing pipeline.
#
# Reads the session transcript, drops tool calls / tool results, chunks
# the remaining user + assistant turns at turn boundaries, redacts
# secret-shaped substrings, and appends one JSONL line per surviving
# chunk to ~/.onlooker/historian/<project-key>/sessions/<session-id>.jsonl.
#
# Hook contract:
#   - Always exits 0. Never blocks session shutdown.
#   - No-ops when historian.enabled is not true.
#   - No-ops when there is no project key, no transcript path, or the
#     transcript is shorter than min_transcript_chars_to_index.
#   - Indexing failures are fail-soft: an emitted historian.indexing.complete
#     with outcome "skipped" + a skip_reason is the worst case.

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

# shellcheck source=../lib/historian-config.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-config.sh"
# shellcheck source=../lib/historian-project-key.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-project-key.sh"
# shellcheck source=../lib/historian-ulid.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-ulid.sh"
# shellcheck source=../lib/historian-storage.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-storage.sh"
# shellcheck source=../lib/historian-emit.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-emit.sh"
# shellcheck source=../lib/historian-transcript.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-transcript.sh"
# shellcheck source=../lib/historian-chunker.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-chunker.sh"
# shellcheck source=../lib/historian-sanitizer.sh
source "${PLUGIN_ROOT}/scripts/lib/historian-sanitizer.sh"

INPUT=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) || CWD=""
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null) || SESSION_ID=""
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null) || TRANSCRIPT_PATH=""
[[ -z "$CWD" ]] && CWD="$(pwd)"
[[ -z "$SESSION_ID" ]] && SESSION_ID="unknown"

REPO_ROOT=$(historian_project_repo_root "$CWD")
historian_config_load "$REPO_ROOT"
historian_config_enabled || exit 0

PROJECT_KEY=$(historian_project_key "$CWD")
[[ -z "$PROJECT_KEY" ]] && exit 0

historian_storage_init "$PROJECT_KEY" || exit 0
REMOTE_URL=$(historian_project_remote_url "$CWD")
historian_storage_write_manifest "$PROJECT_KEY" "$REMOTE_URL" "$REPO_ROOT" || true

# ----------------------------------------------------------------------------
# Indexing started → transcript shape gate → skip_reason if not viable.
# ----------------------------------------------------------------------------

historian_emit "historian.indexing.started" "$SESSION_ID" "$(jq -cn \
	--arg session_id "$SESSION_ID" \
	--argjson transcript_chars 0 \
	'{ session_id: $session_id, transcript_chars: $transcript_chars }')"

SCAN_START_MS=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) \
	|| SCAN_START_MS=$(($(date +%s) * 1000))

_emit_skip() {
	local reason="$1"
	local now_ms duration_ms
	now_ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) \
		|| now_ms=$(($(date +%s) * 1000))
	duration_ms=$((now_ms - SCAN_START_MS))
	historian_emit "historian.indexing.complete" "$SESSION_ID" "$(jq -cn \
		--arg outcome "skipped" \
		--arg skip_reason "$reason" \
		--argjson duration_ms "$duration_ms" \
		'{ outcome: $outcome, skip_reason: $skip_reason, duration_ms: $duration_ms }')"
}

if [[ -z "$TRANSCRIPT_PATH" || ! -f "$TRANSCRIPT_PATH" ]]; then
	_emit_skip "transcript_unavailable"
	exit 0
fi

MIN_CHARS=$(historian_config_get '.historian.indexing.min_transcript_chars_to_index')
[[ -z "$MIN_CHARS" || "$MIN_CHARS" == "null" ]] && MIN_CHARS=1200

TURNS=$(historian_transcript_load "$TRANSCRIPT_PATH")
TRANSCRIPT_CHARS=$(historian_transcript_char_count "$TURNS")
[[ -z "$TRANSCRIPT_CHARS" || "$TRANSCRIPT_CHARS" == "null" ]] && TRANSCRIPT_CHARS=0

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

SANITIZED=$(historian_sanitizer_run "$CHUNKS" "$NEVER_INDEX_PATHS")
KEPT=$(printf '%s' "$SANITIZED" | jq '.kept')
DROPPED=$(printf '%s' "$SANITIZED" | jq '.dropped')

# Re-indexing replaces the existing session file rather than appending,
# so SessionEnd is safely idempotent if re-fired against the same id.
historian_storage_reset_session "$PROJECT_KEY" "$SESSION_ID"

NOW_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CHUNKS_INDEXED=0
KEPT_COUNT=$(printf '%s' "$KEPT" | jq 'length' 2>/dev/null) || KEPT_COUNT=0

for ((i = 0; i < KEPT_COUNT; i++)); do
	CHUNK=$(printf '%s' "$KEPT" | jq -c ".[$i]")
	[[ -z "$CHUNK" || "$CHUNK" == "null" ]] && continue

	CHUNK_ID=$(historian_ulid)
	REDACTION_COUNT=$(printf '%s' "$CHUNK" | jq -r '.redaction_count // 0')

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

	if historian_storage_append_chunk "$PROJECT_KEY" "$SESSION_ID" "$RECORD"; then
		CHUNKS_INDEXED=$((CHUNKS_INDEXED + 1))
		if (( REDACTION_COUNT > 0 )); then
			historian_emit "historian.chunk.sanitized" "$SESSION_ID" "$(jq -cn \
				--arg chunk_id "$CHUNK_ID" \
				--argjson redaction_count "$REDACTION_COUNT" \
				'{ chunk_id: $chunk_id, redaction_count: $redaction_count }')"
		fi
	fi
done

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

NOW_MS=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) \
	|| NOW_MS=$(($(date +%s) * 1000))
DURATION_MS=$((NOW_MS - SCAN_START_MS))

historian_emit "historian.indexing.complete" "$SESSION_ID" "$(jq -cn \
	--arg outcome "ok" \
	--argjson chunks_indexed "$CHUNKS_INDEXED" \
	--argjson chunks_dropped "$DROPPED_COUNT" \
	--argjson duration_ms "$DURATION_MS" \
	'{
		outcome: $outcome,
		chunks_indexed: $chunks_indexed,
		chunks_dropped: $chunks_dropped,
		duration_ms: $duration_ms
	}')"

exit 0

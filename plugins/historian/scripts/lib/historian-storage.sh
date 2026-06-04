#!/usr/bin/env bash
# Storage layout helpers for Historian.
#
# Layout (under $ONLOOKER_DIR/historian/<project-key>/):
#   manifest.json              project metadata (remote_url, repo_root, last_seen_at)
#   sessions/<session_id>.jsonl  append-only chunk records, one per line
#
# Chunk record shape:
#   { chunk_id, session_id, chunk_index, start_turn_index, end_turn_index,
#     body_redacted, body_chars, created_at, source, redaction_count }
#
# Append-only writes keep the indexing path simple and safe to re-run; if a
# session is re-indexed (rare; SessionEnd should fire once), callers can
# truncate the file before appending or accept duplicate chunk records.

historian_storage_root() {
	local base="${ONLOOKER_DIR:-$HOME/.onlooker}"
	printf '%s/historian' "$base"
}

historian_project_dir() {
	local key="$1"
	printf '%s/%s' "$(historian_storage_root)" "$key"
}

historian_sessions_dir() {
	local key="$1"
	printf '%s/sessions' "$(historian_project_dir "$key")"
}

historian_session_file() {
	local key="$1"
	local session_id="$2"
	# Sanitize session_id for filesystem use: strip anything outside
	# [A-Za-z0-9._-]. session_id comes from the Claude Code hook payload
	# and is normally a clean ULID-ish string, but guard against
	# unexpected shapes.
	local safe
	safe=$(printf '%s' "$session_id" | tr -cd '[:alnum:]._-')
	[[ -z "$safe" ]] && safe="unknown"
	printf '%s/%s.jsonl' "$(historian_sessions_dir "$key")" "$safe"
}

historian_storage_init() {
	local key="$1"
	[[ -z "$key" ]] && return 1
	local project_dir
	project_dir=$(historian_project_dir "$key")
	mkdir -p "$project_dir/sessions" 2>/dev/null
}

# Usage: historian_storage_write_manifest <key> <remote_url> <repo_root>
historian_storage_write_manifest() {
	local key="$1"
	local remote_url="$2"
	local repo_root="$3"
	[[ -z "$key" ]] && return 1

	historian_storage_init "$key" || return 1
	local manifest_path now
	manifest_path="$(historian_project_dir "$key")/manifest.json"
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	jq -n \
		--arg key "$key" \
		--arg remote "$remote_url" \
		--arg root "$repo_root" \
		--arg now "$now" \
		'{
			project_key: $key,
			remote_url: (if $remote == "" then null else $remote end),
			repo_root: (if $root == "" then null else $root end),
			last_seen_at: $now
		}' > "$manifest_path" 2>/dev/null
}

# Append a single chunk record (one JSON line) to a session's file.
# Usage: historian_storage_append_chunk <key> <session_id> <chunk_json>
historian_storage_append_chunk() {
	local key="$1"
	local session_id="$2"
	local chunk_json="$3"
	[[ -z "$key" || -z "$session_id" || -z "$chunk_json" ]] && return 1

	historian_storage_init "$key" || return 1
	local path
	path=$(historian_session_file "$key" "$session_id")
	printf '%s\n' "$chunk_json" >> "$path" 2>/dev/null
}

# Count chunks for a session. Returns 0 when the file is absent.
historian_storage_chunk_count() {
	local key="$1"
	local session_id="$2"
	local path
	path=$(historian_session_file "$key" "$session_id")
	[[ -f "$path" ]] || { echo 0; return 0; }
	wc -l < "$path" 2>/dev/null | tr -d ' '
}

# Reset (truncate) the chunk file for a session. Used when SessionEnd
# re-runs against a transcript that was previously indexed.
historian_storage_reset_session() {
	local key="$1"
	local session_id="$2"
	local path
	path=$(historian_session_file "$key" "$session_id")
	[[ -f "$path" ]] || return 0
	: > "$path"
}

# ============================================================================
# Retrieval watermarks (per-session, scoped to the project key)
# ============================================================================

# Path used to hold the per-session retrieval state (count + last_ts) so
# the rate gate persists across UserPromptSubmit invocations within a
# single session. We key on (project, session) so cross-session retrieval
# limits don't leak.
historian_retrieval_state_path() {
	local key="$1"
	local session_id="$2"
	local safe
	safe=$(printf '%s' "$session_id" | tr -cd '[:alnum:]._-')
	[[ -z "$safe" ]] && safe="unknown"
	printf '%s/retrieval-state/%s.json' "$(historian_project_dir "$key")" "$safe"
}

# Read the JSON document at the watermark path. Returns {"count":0,
# "last_ms":0} when the file is absent or unreadable.
historian_retrieval_state_read() {
	local key="$1"
	local session_id="$2"
	local path
	path=$(historian_retrieval_state_path "$key" "$session_id")
	if [[ -f "$path" ]]; then
		jq -c '. // {count:0, last_ms:0}' "$path" 2>/dev/null \
			|| printf '%s' '{"count":0,"last_ms":0}'
	else
		printf '%s' '{"count":0,"last_ms":0}'
	fi
}

# Bump the count and update last_ms.
historian_retrieval_state_write() {
	local key="$1"
	local session_id="$2"
	local count="$3"
	local last_ms="$4"
	local path
	path=$(historian_retrieval_state_path "$key" "$session_id")
	mkdir -p "$(dirname "$path")" 2>/dev/null
	jq -cn --argjson count "$count" --argjson last_ms "$last_ms" \
		'{ count: $count, last_ms: $last_ms }' > "$path" 2>/dev/null
}

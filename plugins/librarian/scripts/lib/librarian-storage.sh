#!/usr/bin/env bash
# Storage layout helpers for Librarian.
#
# Layout (under $ONLOOKER_DIR/librarian/<project-key>/):
#   manifest.json              project metadata: remote_url, repo_root, last_scan_at
#   last_scan.json             { "scanned_at": ISO-8601 } — watermark for incremental scans
#   proposals/<ulid>.json      one pending/resolved proposal per file
#   tombstones/<body_hash>.json one tombstone per rejected/pruned body
#
# All paths inside proposals are stored relative to the repo root where they
# originated. The typed memory store the user maintains lives elsewhere
# (~/.claude/projects/<encoded>/memory/) and is resolved at promotion time.

# ============================================================================
# Path helpers
# ============================================================================

librarian_storage_root() {
	local base="${ONLOOKER_DIR:-$HOME/.onlooker}"
	printf '%s/librarian' "$base"
}

librarian_project_dir() {
	local key="$1"
	printf '%s/%s' "$(librarian_storage_root)" "$key"
}

librarian_proposals_dir() {
	local key="$1"
	printf '%s/proposals' "$(librarian_project_dir "$key")"
}

librarian_tombstones_dir() {
	local key="$1"
	printf '%s/tombstones' "$(librarian_project_dir "$key")"
}

librarian_storage_init() {
	local key="$1"
	[[ -z "$key" ]] && return 1
	local project_dir
	project_dir=$(librarian_project_dir "$key")
	mkdir -p \
		"$project_dir/proposals" \
		"$project_dir/tombstones" 2>/dev/null
}

# ============================================================================
# Manifest
# ============================================================================

# Usage: librarian_storage_write_manifest <key> <remote_url> <repo_root>
librarian_storage_write_manifest() {
	local key="$1"
	local remote_url="$2"
	local repo_root="$3"
	[[ -z "$key" ]] && return 1

	librarian_storage_init "$key" || return 1

	local manifest_path
	manifest_path="$(librarian_project_dir "$key")/manifest.json"
	local now
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

# ============================================================================
# Scan watermark
# ============================================================================

librarian_last_scan_path() {
	local key="$1"
	printf '%s/last_scan.json' "$(librarian_project_dir "$key")"
}

# Read the last scan time as ISO-8601, or empty if never scanned.
librarian_storage_read_last_scan() {
	local key="$1"
	local path
	path=$(librarian_last_scan_path "$key")
	[[ -f "$path" ]] || return 0
	jq -r '.scanned_at // empty' "$path" 2>/dev/null
}

# Write the current time as the new watermark.
librarian_storage_write_last_scan() {
	local key="$1"
	[[ -z "$key" ]] && return 1
	librarian_storage_init "$key" || return 1
	local now path
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	path=$(librarian_last_scan_path "$key")
	jq -n --arg t "$now" '{ scanned_at: $t }' > "$path" 2>/dev/null
}

# ============================================================================
# Proposal storage
# ============================================================================

# Write a single proposal file. Usage:
#   librarian_storage_write_proposal <key> <ulid> <json>
librarian_storage_write_proposal() {
	local key="$1"
	local id="$2"
	local json="$3"
	[[ -z "$key" || -z "$id" || -z "$json" ]] && return 1

	librarian_storage_init "$key" || return 1
	local out_path
	out_path="$(librarian_proposals_dir "$key")/${id}.json"
	printf '%s\n' "$json" > "$out_path" 2>/dev/null && printf '%s' "$out_path"
}

# Read all proposals for a project key as a JSON array. Each entry is the raw
# proposal JSON. Order is unspecified; callers sort/filter as needed.
librarian_storage_load_proposals() {
	local key="$1"
	[[ -z "$key" ]] && { echo '[]'; return 0; }

	local dir
	dir=$(librarian_proposals_dir "$key")
	[[ -d "$dir" ]] || { echo '[]'; return 0; }

	local file all='[]'
	for file in "$dir"/*.json; do
		[[ -f "$file" ]] || continue
		local item
		item=$(jq '.' "$file" 2>/dev/null) || continue
		all=$(printf '%s' "$all" | jq --argjson item "$item" '. + [$item]')
	done
	printf '%s' "$all"
}

# Count pending proposals (status == "pending").
librarian_storage_count_pending() {
	local key="$1"
	local all
	all=$(librarian_storage_load_proposals "$key")
	printf '%s' "$all" | jq '[.[] | select((.status // "pending") == "pending")] | length' 2>/dev/null
}

# ============================================================================
# Tombstone storage
# ============================================================================

# Write a tombstone keyed by body hash. Usage:
#   librarian_storage_write_tombstone <key> <body_hash> <original_filename>
librarian_storage_write_tombstone() {
	local key="$1"
	local body_hash="$2"
	local original_filename="${3:-}"
	[[ -z "$key" || -z "$body_hash" ]] && return 1

	librarian_storage_init "$key" || return 1
	local out_path now
	out_path="$(librarian_tombstones_dir "$key")/${body_hash}.json"
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	jq -n \
		--arg body_hash "$body_hash" \
		--arg original "$original_filename" \
		--arg created "$now" \
		'{
			body_hash: $body_hash,
			original_filename: (if $original == "" then null else $original end),
			created_at: $created
		}' > "$out_path" 2>/dev/null
}

# Returns 0 if a tombstone exists for this body hash (and is not expired).
# Usage: librarian_storage_has_tombstone <key> <body_hash> <ttl_days>
librarian_storage_has_tombstone() {
	local key="$1"
	local body_hash="$2"
	local ttl_days="${3:-180}"
	[[ -z "$key" || -z "$body_hash" ]] && return 1

	local path
	path="$(librarian_tombstones_dir "$key")/${body_hash}.json"
	[[ -f "$path" ]] || return 1

	local created_at age_days
	created_at=$(jq -r '.created_at // empty' "$path" 2>/dev/null)
	[[ -z "$created_at" ]] && return 0

	# Age check via python3 for portable date math.
	age_days=$(python3 -c "
import sys, datetime
created = datetime.datetime.strptime(sys.argv[1], '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
now = datetime.datetime.now(datetime.timezone.utc)
print(int((now - created).days))
" "$created_at" 2>/dev/null) || age_days=0

	(( age_days <= ttl_days ))
}

# Compute a stable hash of a normalized memory body. Used for tombstone keys
# and conflict-state dedup. Strips whitespace runs and lowercases.
librarian_body_hash() {
	local body="$1"
	local normalized
	normalized=$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//')
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$normalized" | shasum -a 256 2>/dev/null | cut -c1-16
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$normalized" | sha256sum 2>/dev/null | cut -c1-16
	else
		return 1
	fi
}

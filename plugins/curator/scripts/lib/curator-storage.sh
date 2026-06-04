#!/usr/bin/env bash
# Storage layout helpers for Curator.
#
# Layout (under $ONLOOKER_DIR/curator/<project-key>/):
#   manifest.json              project metadata (remote_url, repo_root, last_seen_at)
#   last_cheap_scan.json       watermark: when cheap-tier last ran
#   last_llm_sweep.json        watermark: when LLM sweep last ran
#   findings/<ulid>.json       one finding per file (open, acknowledged, or resolved)

# ============================================================================
# Path helpers
# ============================================================================

curator_storage_root() {
	local base="${ONLOOKER_DIR:-$HOME/.onlooker}"
	printf '%s/curator' "$base"
}

curator_project_dir() {
	local key="$1"
	printf '%s/%s' "$(curator_storage_root)" "$key"
}

curator_findings_dir() {
	local key="$1"
	printf '%s/findings' "$(curator_project_dir "$key")"
}

curator_storage_init() {
	local key="$1"
	[[ -z "$key" ]] && return 1
	local project_dir
	project_dir=$(curator_project_dir "$key")
	mkdir -p "$project_dir/findings" 2>/dev/null
}

curator_storage_write_manifest() {
	local key="$1"
	local remote_url="$2"
	local repo_root="$3"
	[[ -z "$key" ]] && return 1

	curator_storage_init "$key" || return 1
	local manifest_path now
	manifest_path="$(curator_project_dir "$key")/manifest.json"
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
# Watermarks
# ============================================================================

curator_last_cheap_scan_path() {
	printf '%s/last_cheap_scan.json' "$(curator_project_dir "$1")"
}

curator_last_llm_sweep_path() {
	printf '%s/last_llm_sweep.json' "$(curator_project_dir "$1")"
}

curator_storage_read_watermark() {
	local path="$1"
	[[ -f "$path" ]] || return 0
	jq -r '.scanned_at // empty' "$path" 2>/dev/null
}

curator_storage_write_watermark() {
	local path="$1"
	[[ -z "$path" ]] && return 1
	mkdir -p "$(dirname "$path")" 2>/dev/null
	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	jq -n --arg t "$now" '{ scanned_at: $t }' > "$path" 2>/dev/null
}

# ============================================================================
# Findings
# ============================================================================

# Write a finding to disk, keyed by ULID. Dedup is by deduped_hash so a
# repeat scan that surfaces the same fact does not write a new finding.
#
# Usage: curator_storage_write_finding <key> <ulid> <json>
curator_storage_write_finding() {
	local key="$1"
	local id="$2"
	local json="$3"
	[[ -z "$key" || -z "$id" || -z "$json" ]] && return 1

	curator_storage_init "$key" || return 1
	local path
	path="$(curator_findings_dir "$key")/${id}.json"
	printf '%s\n' "$json" > "$path" 2>/dev/null && printf '%s' "$path"
}

# Load all findings for a project key as a JSON array.
curator_storage_load_findings() {
	local key="$1"
	[[ -z "$key" ]] && { echo '[]'; return 0; }
	local dir
	dir=$(curator_findings_dir "$key")
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

# Return 0 if a finding with the given dedup hash already exists (open).
curator_storage_has_finding_with_hash() {
	local key="$1"
	local hash="$2"
	[[ -z "$key" || -z "$hash" ]] && return 1
	local existing
	existing=$(curator_storage_load_findings "$key")
	printf '%s' "$existing" | jq -e --arg h "$hash" '
		any(.[]; (.deduped_hash // "") == $h and (.status // "open") == "open")
	' >/dev/null 2>&1
}

curator_storage_count_open() {
	local key="$1"
	local all
	all=$(curator_storage_load_findings "$key")
	printf '%s' "$all" | jq '[.[] | select((.status // "open") == "open")] | length' 2>/dev/null
}

# Open-finding counts grouped by kind. Used by the surfacer to render a
# pointer like "2 path-broken, 1 date-decayed".
#
# jq's group_by groups CONSECUTIVE matches, so the array must be sorted
# by .kind first or the same kind can produce multiple groups (and the
# downstream summary double-counts).
curator_storage_open_counts_by_kind() {
	local key="$1"
	local all
	all=$(curator_storage_load_findings "$key")
	printf '%s' "$all" | jq -c '
		[.[] | select((.status // "open") == "open")]
		| sort_by(.kind)
		| group_by(.kind)
		| map({ kind: .[0].kind, count: length })
		| sort_by(-.count)
	'
}

# Hash a finding's identity-relevant fields. Two findings with the same
# kind + memory_file + matched_phrase (where applicable) share a hash.
# Plain shasum input — no expensive normalization needed.
curator_finding_hash() {
	local raw="$1"
	if command -v shasum >/dev/null 2>&1; then
		printf '%s' "$raw" | shasum -a 256 2>/dev/null | cut -c1-16
	elif command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$raw" | sha256sum 2>/dev/null | cut -c1-16
	else
		return 1
	fi
}

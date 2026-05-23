#!/usr/bin/env bash
# Storage layout and path-validation helpers for Archivist.
#
# Layout (under $ONLOOKER_DIR/archivist/<project-key>/):
#   manifest.json              project metadata: remote_url, repo_root, last_compact_at
#   decisions/<ulid>.json      one decision per file
#   dead_ends/<ulid>.json      one dead-end per file
#   open_questions/<ulid>.json one question per file
#   pinned.json                { "ids": ["01J...", ...] } -- always reinject first
#
# All paths inside artifacts are stored RELATIVE to the repo root. Validation
# happens before write: anything resolving outside the repo (or that does not
# exist) is dropped. This is the second line of defense against cross-project
# contamination after project-key isolation.

# ============================================================================
# Path helpers
# ============================================================================

# Root directory for archivist artifacts. Honors $ONLOOKER_DIR if set so tests
# can isolate writes.
archivist_storage_root() {
	local base="${ONLOOKER_DIR:-$HOME/.onlooker}"
	printf '%s/archivist' "$base"
}

archivist_project_dir() {
	local key="$1"
	printf '%s/%s' "$(archivist_storage_root)" "$key"
}

archivist_kind_dir() {
	local key="$1"
	local kind="$2"
	printf '%s/%s' "$(archivist_project_dir "$key")" "$kind"
}

# Ensure the directory tree exists for a given project key.
archivist_storage_init() {
	local key="$1"
	[[ -z "$key" ]] && return 1
	local project_dir
	project_dir=$(archivist_project_dir "$key")
	mkdir -p \
		"$project_dir/decisions" \
		"$project_dir/dead_ends" \
		"$project_dir/open_questions" 2>/dev/null
}

# Write or update the project manifest.
# Usage: archivist_storage_write_manifest <key> <remote_url> <repo_root>
archivist_storage_write_manifest() {
	local key="$1"
	local remote_url="$2"
	local repo_root="$3"
	[[ -z "$key" ]] && return 1

	archivist_storage_init "$key" || return 1

	local manifest_path
	manifest_path="$(archivist_project_dir "$key")/manifest.json"
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
			last_compact_at: $now,
			source: "local"
		}' > "$manifest_path" 2>/dev/null
}

# ============================================================================
# Path validation (drop entries pointing outside the repo)
# ============================================================================

# Given a repo root and a path string (possibly absolute, possibly relative,
# possibly with ../), echo the path relativized to the repo root iff it resolves
# inside the repo AND the file exists. Otherwise echo nothing.
#
# Worktrees: an absolute path that lives in a checked-out worktree of the same
# repo is considered "in repo" — we resolve against the worktree's toplevel.
archivist_validate_repo_path() {
	local repo_root="$1"
	local candidate="$2"
	[[ -z "$repo_root" || -z "$candidate" ]] && return 0
	[[ ! -d "$repo_root" ]] && return 0

	local abs_root
	abs_root=$(cd "$repo_root" 2>/dev/null && pwd -P) || return 0

	local resolved
	if [[ "$candidate" == /* ]]; then
		resolved="$candidate"
	else
		resolved="$repo_root/$candidate"
	fi

	# Resolve to a physical path so symlinks (e.g. macOS /var -> /private/var)
	# don't cause a false-negative against abs_root. realpath handles
	# nonexistent leaf names via strict=False so we can still emit the
	# canonical form and let the -e check below decide.
	resolved=$(python3 -c '
import os, sys
print(os.path.realpath(sys.argv[1]))
' "$resolved" 2>/dev/null) || return 0

	# Must live under repo root and exist on disk.
	case "$resolved" in
		"$abs_root"|"$abs_root"/*) : ;;
		*) return 0 ;;
	esac

	[[ -e "$resolved" ]] || return 0

	# Echo relative form (strip "$abs_root/" prefix).
	if [[ "$resolved" == "$abs_root" ]]; then
		printf '.'
	else
		printf '%s' "${resolved#"$abs_root/"}"
	fi
}

# Given a JSON array of file path strings, return a JSON array containing only
# the paths that pass validation, relativized to the repo root.
# Usage: cleaned=$(archivist_validate_paths_array "$repo_root" "$paths_json")
archivist_validate_paths_array() {
	local repo_root="$1"
	local paths_json="$2"
	[[ -z "$paths_json" || "$paths_json" == "null" ]] && { echo '[]'; return 0; }

	local out='[]'
	local count i candidate cleaned
	count=$(printf '%s' "$paths_json" | jq 'length' 2>/dev/null) || count=0
	for ((i = 0; i < count; i++)); do
		candidate=$(printf '%s' "$paths_json" | jq -r ".[$i]" 2>/dev/null) || continue
		[[ -z "$candidate" || "$candidate" == "null" ]] && continue
		cleaned=$(archivist_validate_repo_path "$repo_root" "$candidate")
		[[ -z "$cleaned" ]] && continue
		out=$(printf '%s' "$out" | jq --arg p "$cleaned" '. + [$p]')
	done
	printf '%s' "$out"
}

# ============================================================================
# Artifact write
# ============================================================================

# Write a single artifact file. Returns the path written on success.
# Usage: archivist_storage_write_artifact <key> <kind> <id> <json>
archivist_storage_write_artifact() {
	local key="$1"
	local kind="$2"
	local id="$3"
	local json="$4"
	[[ -z "$key" || -z "$kind" || -z "$id" || -z "$json" ]] && return 1

	case "$kind" in
		decisions|dead_ends|open_questions) : ;;
		*) return 1 ;;
	esac

	archivist_storage_init "$key" || return 1
	local out_path
	out_path="$(archivist_kind_dir "$key" "$kind")/${id}.json"
	printf '%s\n' "$json" > "$out_path" 2>/dev/null && printf '%s' "$out_path"
}

# ============================================================================
# Artifact read (for injection)
# ============================================================================

# Read all artifacts for a given project key as a single JSON array, with each
# entry augmented with a `kind` field. Output is sorted by `updated_at`
# descending. Pinned IDs (from pinned.json) come first regardless of recency.
#
# Usage: items=$(archivist_storage_load_ranked <key>)
archivist_storage_load_ranked() {
	local key="$1"
	[[ -z "$key" ]] && { echo '[]'; return 0; }

	local project_dir
	project_dir=$(archivist_project_dir "$key")
	[[ ! -d "$project_dir" ]] && { echo '[]'; return 0; }

	local pinned_file="$project_dir/pinned.json"
	local pinned_json='{"ids":[]}'
	[[ -f "$pinned_file" ]] && pinned_json=$(cat "$pinned_file" 2>/dev/null) || true

	local kind file all='[]'
	for kind in decisions dead_ends open_questions; do
		[[ -d "$project_dir/$kind" ]] || continue
		for file in "$project_dir/$kind"/*.json; do
			[[ -f "$file" ]] || continue
			local item
			item=$(jq --arg k "$kind" '. + {kind: $k}' "$file" 2>/dev/null) || continue
			all=$(printf '%s' "$all" | jq --argjson item "$item" '. + [$item]')
		done
	done

	printf '%s' "$all" | jq --argjson pinned "$pinned_json" '
		($pinned.ids // []) as $pids
		| map(. + { pinned: (.id as $id | $pids | index($id) != null) })
		| sort_by([
			(if .pinned then 0 else 1 end),
			-((.updated_at // .created_at // "") | sub("[^0-9]"; ""; "g") | tonumber? // 0)
		])
	'
}

#!/usr/bin/env bash
# Memory store reader for Curator.
#
# Parses ~/.claude/projects/<encoded-project>/memory/MEMORY.md and the
# referenced *.md files. Returns a JSON array of memory records:
#
#   [
#     {
#       "filename": "feedback_no_trailing_summaries.md",
#       "title": "...",                       # from frontmatter `name` or MEMORY.md link
#       "type": "feedback",                   # from frontmatter `type`
#       "body": "...",                        # everything after the frontmatter
#       "exists": true,                       # false when MEMORY.md points at a missing file
#       "frontmatter_parsed": true|false
#     },
#     ...
#   ]
#
# Orphans (files present in the memory dir but not referenced from MEMORY.md)
# get their own record with `referenced: false`. Broken index entries
# (referenced by MEMORY.md but missing on disk) get `exists: false`.

# Resolve the memory store path. The runtime resolves
# $CLAUDE_PROJECT_ENCODED — when unset, the caller provides it explicitly.
#
# Usage: curator_memory_resolve_path <memory_store_path_template>
# Returns the resolved absolute path, or empty if it can't be resolved.
curator_memory_resolve_path() {
	local template="$1"
	[[ -z "$template" ]] && return 0
	local encoded="${CLAUDE_PROJECT_ENCODED:-}"
	# Best-effort interpolation. The template may contain ${HOME} and
	# ${CLAUDE_PROJECT_ENCODED}.
	local resolved
	resolved="${template//\$\{HOME\}/${HOME:-}}"
	resolved="${resolved//\$\{CLAUDE_PROJECT_ENCODED\}/${encoded}}"
	# If the encoded var is missing, the path still contains the literal
	# placeholder; caller treats empty as "skip the audit".
	if [[ "$resolved" == *'${CLAUDE_PROJECT_ENCODED}'* ]]; then
		return 0
	fi
	printf '%s' "$resolved"
}

# Parse a single memory file. Returns a JSON object on stdout.
# Usage: curator_memory_parse_file <abs_path> <referenced_bool>
curator_memory_parse_file() {
	local path="$1"
	local referenced="${2:-true}"
	[[ -z "$path" ]] && return 0

	local filename
	filename="$(basename "$path")"

	if [[ ! -f "$path" ]]; then
		jq -cn \
			--arg filename "$filename" \
			--argjson referenced "$referenced" \
			'{
				filename: $filename,
				title: null, type: null, body: "",
				exists: false, referenced: $referenced,
				frontmatter_parsed: false
			}'
		return 0
	fi

	local raw
	raw=$(cat "$path" 2>/dev/null || true)
	[[ -z "$raw" ]] && raw=""

	local has_fm name desc type body fm_parsed="false"
	if [[ "$raw" == "---"* ]]; then
		# YAML frontmatter present. Extract simple `key: value` lines until
		# the closing `---`. Fancier YAML (nested, lists) isn't expected in
		# the auto-memory format.
		local fm_block
		fm_block=$(printf '%s' "$raw" | awk '
			NR == 1 && /^---/ { in_fm = 1; next }
			in_fm && /^---/ { in_fm = 0; exit }
			in_fm { print }
		')
		name=$(printf '%s' "$fm_block" | sed -nE 's/^name:[[:space:]]*(.*)$/\1/p' | head -1)
		desc=$(printf '%s' "$fm_block" | sed -nE 's/^description:[[:space:]]*(.*)$/\1/p' | head -1)
		type=$(printf '%s' "$fm_block" | sed -nE 's/^type:[[:space:]]*(.*)$/\1/p' | head -1)
		body=$(printf '%s' "$raw" | awk '
			BEGIN { in_fm = 0; seen_close = 0 }
			NR == 1 && /^---/ { in_fm = 1; next }
			in_fm && /^---/ { in_fm = 0; seen_close = 1; next }
			seen_close { print }
		')
		fm_parsed="true"
		has_fm="true"
	else
		# No frontmatter — treat the whole body as content; type unknown.
		name=""
		desc=""
		type=""
		body="$raw"
		fm_parsed="false"
		has_fm="false"
	fi

	jq -cn \
		--arg filename "$filename" \
		--arg name "$name" \
		--arg desc "$desc" \
		--arg type "$type" \
		--arg body "$body" \
		--argjson referenced "$referenced" \
		--argjson fm_parsed "$fm_parsed" \
		'{
			filename: $filename,
			title: (if $name == "" then null else $name end),
			description: (if $desc == "" then null else $desc end),
			type: (if $type == "" then null else $type end),
			body: $body,
			exists: true,
			referenced: $referenced,
			frontmatter_parsed: $fm_parsed
		}'
}

# Load every memory file referenced by MEMORY.md plus every file in the dir.
# Output: JSON array of memory records (as defined at the top of this file).
#
# Usage: curator_memory_load_all <memory_dir_abs>
curator_memory_load_all() {
	local mem_dir="$1"
	[[ -z "$mem_dir" || ! -d "$mem_dir" ]] && { echo '[]'; return 0; }

	# 1. Parse MEMORY.md for referenced filenames.
	local index_path="${mem_dir}/MEMORY.md"
	local referenced_list=()
	if [[ -f "$index_path" ]]; then
		# Match the standard line format: `- [Title](file.md) — hook`
		while IFS= read -r line; do
			referenced_list+=("$line")
		done < <(grep -oE '\[[^]]+\]\([^)]+\)' "$index_path" 2>/dev/null \
			| sed -E 's/.*\(([^)]+)\)/\1/' | awk '{ print }')
	fi

	# 2. Build the canonical set of referenced filenames.
	local referenced_json='[]'
	if [[ ${#referenced_list[@]} -gt 0 ]]; then
		referenced_json=$(printf '%s\n' "${referenced_list[@]}" | jq -R . | jq -s .)
	fi

	# 3. Visit each referenced filename (broken or not) plus every *.md
	#    on disk that wasn't referenced.
	local all='[]'
	local fname rec
	local seen_json='{}'

	# Referenced first — preserves MEMORY.md ordering for downstream display.
	local refcount
	refcount=$(printf '%s' "$referenced_json" | jq 'length')
	local i
	for ((i = 0; i < refcount; i++)); do
		fname=$(printf '%s' "$referenced_json" | jq -r ".[$i]")
		[[ -z "$fname" || "$fname" == "null" ]] && continue
		# Skip MEMORY.md itself if it self-references.
		[[ "$fname" == "MEMORY.md" ]] && continue
		rec=$(curator_memory_parse_file "${mem_dir}/${fname}" true)
		[[ -z "$rec" ]] && continue
		all=$(printf '%s' "$all" | jq --argjson rec "$rec" '. + [$rec]')
		seen_json=$(printf '%s' "$seen_json" | jq --arg f "$fname" '. + {($f): true}')
	done

	# Then any orphans (files on disk not referenced from MEMORY.md).
	local file
	for file in "$mem_dir"/*.md; do
		[[ -f "$file" ]] || continue
		fname="$(basename "$file")"
		[[ "$fname" == "MEMORY.md" ]] && continue
		local already_seen
		already_seen=$(printf '%s' "$seen_json" | jq -r --arg f "$fname" '.[$f] // false')
		[[ "$already_seen" == "true" ]] && continue
		rec=$(curator_memory_parse_file "$file" false)
		[[ -z "$rec" ]] && continue
		all=$(printf '%s' "$all" | jq --argjson rec "$rec" '. + [$rec]')
	done

	printf '%s' "$all"
}

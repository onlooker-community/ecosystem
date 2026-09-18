#!/usr/bin/env bash
# Reads archivist artifacts for the librarian scan pipeline.
#
# Archivist stores per-session artifacts under:
#   $ONLOOKER_DIR/archivist/<project-key>/{decisions,dead_ends,open_questions}/<ulid>.json
#
# Each artifact has the shape (see archivist's storage.sh):
#   { id, kind, project_key, source, created_at, updated_at, summary,
#     detail, files, session_id, trigger }
#
# Librarian reads the same project-key directory and filters by created_at,
# returning candidates newer than the watermark.

# Resolve the archivist project dir for a given project key.
# Returns empty if archivist artifacts are not present.
librarian_archivist_project_dir() {
	local project_key="$1"
	[[ -z "$project_key" ]] && return 0
	local base="${ONLOOKER_DIR:-$HOME/.onlooker}"
	local dir="${base}/archivist/${project_key}"
	[[ -d "$dir" ]] || return 0
	printf '%s' "$dir"
}

# Load archivist artifacts created since the given watermark.
#
# Usage: librarian_archivist_load_since <project_key> <watermark_iso>
#
# Watermark format: ISO-8601 (e.g., "2026-06-01T12:34:56Z"). When the
# watermark is empty, all artifacts are returned (used on first scan).
#
# Output: JSON array, one element per artifact, in chronological order.
librarian_archivist_load_since() {
	local project_key="$1"
	local watermark="${2:-}"

	local project_dir
	project_dir=$(librarian_archivist_project_dir "$project_key")
	[[ -z "$project_dir" ]] && { echo '[]'; return 0; }

	local kind file
	local files=()
	for kind in decisions dead_ends open_questions; do
		[[ -d "${project_dir}/${kind}" ]] || continue
		for file in "${project_dir}/${kind}"/*.json; do
			[[ -f "$file" ]] || continue
			files+=("$file")
		done
	done

	[[ ${#files[@]} -eq 0 ]] && { echo '[]'; return 0; }

	# One jq for the whole corpus, not two per file.
	#
	# This loop used to parse each artifact with `jq '.'` and then read its
	# created_at with a second `jq -r` — every artifact ever written for the
	# project, walked in full before the watermark could exclude any of it, and
	# an O(n^2) `. + [$item]` append on top. Measured on a 703-artifact project:
	# 3.4 SECONDS to return zero artifacts, against the 1500ms window the CLI
	# gives the entire SessionEnd hook batch. The hook was killed mid-read on
	# essentially every session, which is why librarian stopped reporting: a
	# killed hook emits no scan.started, so the outage was invisible on the bus.
	#
	# The cost has to be flat in corpus size, not merely smaller, because the
	# corpus only ever grows. See ecosystem-449.68.
	local result
	if result=$(jq -s --arg watermark "$watermark" '
		map(select(type == "object"))
		| map(select(
			$watermark == ""
			or (((.created_at // .updated_at // "")) as $c
				| $c != "" and $c > $watermark)))
		| sort_by(.created_at // .updated_at // "")
	' "${files[@]}" 2>/dev/null); then
		printf '%s' "$result"
		return 0
	fi

	# A batch parse aborts on the first malformed byte, which would let one
	# corrupt artifact blank an entire scan. The per-file read cannot do that,
	# so it stays as the fallback: slow, but it costs only the broken file.
	# Also covers the case where the argument list is too long to exec.
	local all='[]' item created_at
	for file in "${files[@]}"; do
		item=$(jq '.' "$file" 2>/dev/null) || continue
		[[ -z "$item" || "$item" == "null" ]] && continue

		if [[ -n "$watermark" ]]; then
			created_at=$(printf '%s' "$item" | jq -r '.created_at // .updated_at // ""' 2>/dev/null)
			[[ -z "$created_at" ]] && continue
			# Lexicographic compare works for ISO-8601 UTC strings.
			if [[ "$created_at" < "$watermark" || "$created_at" == "$watermark" ]]; then
				continue
			fi
		fi

		all=$(printf '%s' "$all" | jq --argjson item "$item" '. + [$item]')
	done

	# Sort chronologically; downstream classifier groups by session_id and
	# benefits from stable order.
	printf '%s' "$all" | jq 'sort_by(.created_at // .updated_at // "")'
}

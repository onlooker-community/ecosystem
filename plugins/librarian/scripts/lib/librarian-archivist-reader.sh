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
# Librarian reads the same project-key directory and returns the artifacts
# archivist wrote at or after the watermark, by file mtime (ONL-200), falling
# back to created_at only when no stat can report mtimes.

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

# Load one archivist artifact by its id, printing nothing when it is gone.
#
# reconsider needs a single artifact rather than a watermark window, so this
# walks the three kind directories instead of reusing load_since's corpus-wide
# jq. The kind list must stay identical to load_since's: a directory readable
# here but not there would make reconsider recover artifacts the scan itself
# never sees.
#
# Usage: librarian_archivist_load_by_id <project_key> <artifact_id>
librarian_archivist_load_by_id() {
	local project_key="$1"
	local artifact_id="$2"
	[[ -z "$project_key" || -z "$artifact_id" ]] && return 0

	# The id comes off declined.jsonl, so it is untrusted input to a path. Only
	# a bare ULID may through: anything with a slash or .. in it would otherwise
	# read outside the project directory.
	[[ "$artifact_id" =~ ^[0-9A-HJKMNP-TV-Z]{26}$ ]] || return 0

	local project_dir
	project_dir=$(librarian_archivist_project_dir "$project_key")
	[[ -z "$project_dir" ]] && return 0

	local kind file
	for kind in decisions dead_ends open_questions; do
		file="${project_dir}/${kind}/${artifact_id}.json"
		[[ -f "$file" ]] || continue
		jq -c 'objects' "$file" 2>/dev/null
		return 0
	done
	return 0
}

# Load archivist artifacts written since the given watermark.
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

	# Window on when archivist WROTE each file, not on its created_at.
	#
	# archivist-mine stamps created_at with the commit time and runs alongside
	# this scan at SessionEnd. When the scan reads first, the artifact lands
	# afterward with a created_at older than the watermark the scan then writes,
	# and a created_at window excludes it from every later scan. That stranded
	# every commit mined in a race the scan won, and with it the lesson_auto
	# stage, which only runs behind a non-empty window (ONL-200).
	#
	# Inclusive of the watermark's own second: the watermark is the scan's
	# start floored to the second, and stat reports whole seconds, so a file
	# written just after the read can share it. What that re-reads from just
	# before the read is dropped downstream as a duplicate.
	#
	# One stat for the whole corpus, so the cost stays flat (see below). GNU
	# first: BSD rejects -c outright, whereas GNU reads -f as --file-system and
	# prints filesystem data before failing. If neither works, fall back to the
	# created_at window rather than to nothing or to everything.
	local by_created_at=1
	if [[ -n "$watermark" ]]; then
		local watermark_epoch stats
		watermark_epoch=$(jq -rn --arg w "$watermark" '$w | fromdateiso8601' 2>/dev/null) \
			|| watermark_epoch=""
		if [[ -n "$watermark_epoch" ]] \
			&& { stats=$(stat -c '%Y %n' "${files[@]}" 2>/dev/null) \
				|| stats=$(stat -f '%m %N' "${files[@]}" 2>/dev/null); }; then
			by_created_at=0
			files=()
			local mtime path
			while IFS=' ' read -r mtime path; do
				[[ "$mtime" =~ ^[0-9]+$ ]] || continue
				[[ "$mtime" -ge "$watermark_epoch" ]] && files+=("$path")
			done <<< "$stats"
			[[ ${#files[@]} -eq 0 ]] && { echo '[]'; return 0; }
		fi
	fi

	# Past this point $watermark is the created_at fallback only: once the
	# mtime filter has run, the files list already IS the window.
	[[ "$by_created_at" == "0" ]] && watermark=""

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

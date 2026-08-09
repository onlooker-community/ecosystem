#!/usr/bin/env bash
# Storage for the lesson subtree.
#
#   <project_dir>/lessons/proposals/<ulid>.json   awaiting human confirmation
#   <project_dir>/lessons/approved/<ulid>.json    jury passed (written by 4z8.4)
#   <project_dir>/lessons/declined.jsonl          append-only, never re-judged
#
# Lessons live apart from librarian's memory `proposals/` on purpose: a memory
# promotion writes to this machine, a lesson proposal is a step toward
# publishing beyond it. Separate trees keep a confirmation surface from
# merging the two by accident.
#
# Requires librarian-storage.sh (librarian_project_dir) and librarian-ulid.sh.

librarian_lessons_dir() {
	local key="$1"
	printf '%s/lessons' "$(librarian_project_dir "$key")"
}

librarian_lesson_storage_init() {
	local key="$1"
	[[ -z "$key" ]] && return 1
	local dir
	dir=$(librarian_lessons_dir "$key")
	mkdir -p "$dir/proposals" "$dir/approved" 2>/dev/null
}

# Write one candidate. Prints the ULID on success.
# Usage: librarian_lesson_write_proposal <key> <candidate_json> <artifact_id>
librarian_lesson_write_proposal() {
	local key="$1"
	local candidate="$2"
	local artifact_id="$3"
	[[ -z "$key" || -z "$candidate" || -z "$artifact_id" ]] && return 1

	librarian_lesson_storage_init "$key" || return 1

	local id now out
	id=$(librarian_ulid) || return 1
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	out="$(librarian_lessons_dir "$key")/proposals/${id}.json"

	jq -n \
		--arg id "$id" \
		--arg artifact_id "$artifact_id" \
		--arg created "$now" \
		--argjson candidate "$candidate" \
		'{
			id: $id,
			artifact_id: $artifact_id,
			created_at: $created,
			status: "pending",
			candidate: $candidate
		}' > "$out" 2>/dev/null || return 1

	printf '%s' "$id"
}

# Append one decline. Only ever called for real determinations — never for a
# missing CLI, a timeout, or an empty response. Recording an outage here would
# bury a good artifact permanently, because the watermark has already moved
# past it and declined entries are never re-read.
#
# Usage: librarian_lesson_append_declined <key> <artifact_id> <reason> [detail]
librarian_lesson_append_declined() {
	local key="$1"
	local artifact_id="$2"
	local reason="$3"
	local detail="${4:-}"
	[[ -z "$key" || -z "$artifact_id" || -z "$reason" ]] && return 1

	librarian_lesson_storage_init "$key" || return 1

	local now line
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	line=$(jq -cn \
		--arg artifact_id "$artifact_id" \
		--arg reason "$reason" \
		--arg detail "$detail" \
		--arg at "$now" \
		'{
			artifact_id: $artifact_id,
			reason: $reason,
			detail: (if $detail == "" then null else $detail end),
			declined_at: $at
		}') || return 1

	printf '%s\n' "$line" >> "$(librarian_lessons_dir "$key")/declined.jsonl"
}

# Returns 0 when this artifact has already been handled.
#
# The watermark cannot answer this: last_scan.json records only *when* we
# scanned, not which artifacts were considered. Idempotency is artifact-keyed
# and permanent, unlike tombstones (body-hash keyed, TTL'd).
#
# Usage: librarian_lesson_seen <key> <artifact_id>
librarian_lesson_seen() {
	local key="$1"
	local artifact_id="$2"
	[[ -z "$key" || -z "$artifact_id" ]] && return 1

	local dir
	dir=$(librarian_lessons_dir "$key")

	# -R reads each line as a raw string and fromjson? yields nothing for a
	# line that fails to parse, instead of aborting the whole jq invocation.
	# Without this, one truncated trailing line (e.g. a process killed
	# mid-append) makes jq exit 5 for the entire file, and every artifact
	# declined before that line reads back as "not seen."
	#
	# `objects` after fromjson? is load-bearing, not decorative: fromjson?
	# only guards the *parse*, not what comes after it in the pipe. A line
	# that is valid JSON but not an object (a bare `123`, `true`, `"str"`, or
	# `[1,2,3]`) parses cleanly, then `.artifact_id` indexing on that
	# non-object errors out the whole jq invocation — the same
	# every-prior-decline-reads-as-unseen failure the -R/fromjson? guard
	# above exists to prevent, just reached through a different door.
	# `objects` filters those values out before `.artifact_id` ever runs.
	if [[ -f "$dir/declined.jsonl" ]] \
		&& jq -Re --arg a "$artifact_id" 'fromjson? | objects | select(.artifact_id == $a)' \
			"$dir/declined.jsonl" >/dev/null 2>&1; then
		return 0
	fi

	local f
	for f in "$dir"/proposals/*.json "$dir"/approved/*.json; do
		[[ -f "$f" ]] || continue
		if jq -e --arg a "$artifact_id" '.artifact_id == $a' "$f" >/dev/null 2>&1; then
			return 0
		fi
	done

	return 1
}

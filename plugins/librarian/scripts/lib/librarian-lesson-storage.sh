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

# Write a file atomically: temp in the same directory, then mv.
#
# `printf > "$path"` truncates before writing, so an interrupted write leaves
# a zero-byte file. For a proposal that is permanently stuck: every verb
# refuses it with "unrecognized status: " and list_pending hides it, so even
# unconfirm — the recovery verb — cannot bring it back.
#
# Usage: librarian_lesson_write_atomic <path> <content>
librarian_lesson_write_atomic() {
	local path="$1"
	local content="$2"
	local tmp
	tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || return 1
	printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
	mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
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
# `verdict` is emitted with --argjson so it lands as a nested object, not a
# serialized string: consumers read .verdict.judges[].score directly. Rows
# written by the transform have no verdict and simply lack the key — a format
# failure has no jury.
#
# Usage: librarian_lesson_append_declined <key> <artifact_id> <reason> [detail] [verdict_json]
librarian_lesson_append_declined() {
	local key="$1"
	local artifact_id="$2"
	local reason="$3"
	local detail="${4:-}"
	local verdict="${5:-}"
	[[ -z "$key" || -z "$artifact_id" || -z "$reason" ]] && return 1

	librarian_lesson_storage_init "$key" || return 1

	local now line
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	if [[ -n "$verdict" ]]; then
		line=$(jq -cn \
			--arg artifact_id "$artifact_id" \
			--arg reason "$reason" \
			--arg detail "$detail" \
			--arg at "$now" \
			--argjson verdict "$verdict" \
			'{
				artifact_id: $artifact_id,
				reason: $reason,
				detail: (if $detail == "" then null else $detail end),
				declined_at: $at,
				verdict: $verdict
			}') || return 1
	else
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
	fi

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

	# ===================================================================
	# proposals/ IS THE SOLE DEDUP SOURCE FOR AN APPROVED LESSON.
	# PRUNING proposals/ SILENTLY BREAKS DEDUP. See ecosystem-d0m.
	# ===================================================================
	#
	# A declined artifact is covered by declined.jsonl above — a terminal
	# record keyed by artifact_id that outlives its proposal. An APPROVED one
	# has no equivalent: the pool entry is ZLesson, a strictObject whose key
	# set has no artifact_id and cannot gain one (an extra key fails ingest —
	# see librarian-lesson-promote.sh's key-set comment). So nothing promote
	# writes can answer "was this artifact already handled?"
	#
	# This loop used to scan approved/*.json too. That branch could never
	# match, and the test covering it fabricated an {artifact_id: ...} file
	# promote cannot produce — dead code with a green test in front of it,
	# which is why it survived. Dropped rather than left as a decorative
	# safety net that reads like coverage.
	#
	# The consequence, accepted deliberately: prune a promoted lesson's
	# proposal and its artifact reads as unseen, so it is re-transformed
	# (Haiku), re-confirmed BY THE HUMAN AGAIN, and re-judged (Opus),
	# producing a duplicate pool entry for a lesson already promoted.
	#
	# The alternative was an artifact_id -> lesson id index (or a per-entry
	# sidecar) to make the pool self-identifying. Neither buys anything until
	# someone actually wants to prune, and both add a surface that can drift
	# from the directory — so the requirement is stated instead of engineered
	# around. Build the index FIRST if you ever need to prune; the tripwire
	# test is "an approved lesson is NOT seen once its proposal is gone" in
	# test/bats/librarian-lesson-promote.bats.
	local f
	for f in "$dir"/proposals/*.json; do
		[[ -f "$f" ]] || continue
		if jq -e --arg a "$artifact_id" '.artifact_id == $a' "$f" >/dev/null 2>&1; then
			return 0
		fi
	done

	return 1
}

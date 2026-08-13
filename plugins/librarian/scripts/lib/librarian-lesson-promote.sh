#!/usr/bin/env bash
# Terminal state for the lesson-promotion pipeline.
#
# A judged proposal becomes either a ZLesson-shaped pool entry awaiting sync,
# or a row in the declined ledger. Nothing crosses the network — the sync
# service that drains the pool does not exist yet.
#
# Requires librarian-lesson-storage.sh and librarian-author-key.sh.
#
# Exposes:
#   librarian_lesson_promote <key> <lesson_id>

# Map a lesson's visibility to the contract's `source` enum.
#
# NOT a rename: ZSource is local|org|public while visibility is
# private|org|public. `private` maps to `local` — the tier that never leaves
# this machine maps to the source meaning "not from anywhere else". Emitting
# "private" would fail ingest.
_librarian_lesson_source_for_visibility() {
	case "${1:-}" in
		private) printf 'local' ;;
		org)     printf 'org' ;;
		public)  printf 'public' ;;
		*)       return 1 ;;
	esac
	return 0
}

# Write a file atomically: temp in the same directory, then mv.
#
# ecosystem-a3b is open against three existing `printf > path` sites in this
# plugin, each of which truncates before writing. These are new sites; adding
# a fourth instance of a known bug would be a choice, not an inheritance.
_librarian_lesson_write_atomic() {
	local path="$1"
	local content="$2"
	local tmp
	tmp=$(mktemp "${path}.XXXXXX" 2>/dev/null) || return 1
	printf '%s\n' "$content" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
	mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Promote one judged proposal to its terminal record.
#
# Returns 0 on success, including the already-promoted no-op. Returns 1 on
# refusal or failure, having written NOTHING — the proposal stays `approved`
# without `promoted_at`, which is the state a standalone re-run resolves.
#
# Ordering is load-bearing: the terminal record lands BEFORE the stamp. A
# stamp followed by a failed write would leave the lesson marked done, present
# nowhere, and invisible to a reconcile that keys on the stamp's absence.
#
# Usage: librarian_lesson_promote <key> <lesson_id>
librarian_lesson_promote() {
	local key="$1"
	local lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	local dir path
	dir="$(librarian_lessons_dir "$key")"
	path="${dir}/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	# Already promoted: a no-op success, so a reconcile loop is safe to run
	# over everything. Same precedent as unconfirm on a pending lesson.
	if [[ "$(jq -r 'has("promoted_at")' "$path" 2>/dev/null)" == "true" ]]; then
		return 0
	fi

	local current_status visibility
	current_status=$(jq -r '.status // ""' "$path" 2>/dev/null)
	visibility=$(jq -r '.visibility // ""' "$path" 2>/dev/null)

	case "$current_status" in
		approved|rejected) ;;
		confirmed)
			printf 'Lesson %s has not been judged yet; nothing to promote.\n' "$lesson_id" >&2
			return 1
			;;
		*)
			printf 'Lesson %s cannot be promoted from status: %s\n' "$lesson_id" "$current_status" >&2
			return 1
			;;
	esac

	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	if [[ "$current_status" == "approved" ]]; then
		local source author_key entry pool_path
		source=$(_librarian_lesson_source_for_visibility "$visibility") || {
			printf 'Lesson %s has an unrecognized visibility: %s\n' "$lesson_id" "$visibility" >&2
			return 1
		}
		author_key=$(librarian_author_key "$visibility") || {
			printf 'Lesson %s: cannot derive an author key; nothing written.\n' "$lesson_id" >&2
			return 1
		}

		# Exactly ZLesson's key set — it is a strictObject, so an extra key
		# fails ingest as surely as a missing one. A private entry gets
		# judges: 0 and is deliberately not ingest-valid; it never syncs.
		entry=$(jq -cn \
			--argjson p "$(cat "$path")" \
			--arg ak "$author_key" \
			--arg src "$source" \
			--arg now "$now" \
			'{
				id: $p.id,
				schema_version: 2,
				claim: $p.candidate.claim,
				rationale: $p.candidate.rationale,
				evidence: $p.candidate.evidence,
				applies_to: $p.candidate.applies_to,
				visibility: $p.visibility,
				consensus: {
					judges: (($p.verdict.judges // []) | length),
					agreed: ([($p.verdict.judges // [])[] | select(.passed == true)] | length),
					decided_at: $p.judged_at
				},
				status: "active",
				superseded_by: null,
				source: $src,
				author_key: $ak,
				promoted_at: $now
			}' 2>/dev/null) || {
			printf 'Lesson %s: cannot build a pool entry.\n' "$lesson_id" >&2
			return 1
		}

		pool_path="${dir}/approved/${lesson_id}.json"
		if [[ ! -f "$pool_path" ]]; then
			_librarian_lesson_write_atomic "$pool_path" "$entry" || {
				printf 'Lesson %s: cannot write the pool entry.\n' "$lesson_id" >&2
				return 1
			}
		fi
	else
		local artifact_id reason verdict
		artifact_id=$(jq -r '.artifact_id // ""' "$path" 2>/dev/null)
		reason=$(jq -r '.verdict.reason // "rejected"' "$path" 2>/dev/null)
		verdict=$(jq -c '.verdict // {}' "$path" 2>/dev/null)
		librarian_lesson_append_declined "$key" "$artifact_id" "$reason" "" "$verdict" || {
			printf 'Lesson %s: cannot append to the declined ledger.\n' "$lesson_id" >&2
			return 1
		}
	fi

	# Stamp LAST. See the ordering note above.
	local updated
	updated=$(jq --arg t "$now" '.promoted_at = $t' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	_librarian_lesson_write_atomic "$path" "$updated"
}

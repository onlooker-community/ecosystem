#!/usr/bin/env bash
# Lesson confirmation — the human intent filter.
#
# The human picks which candidates go to the jury and their visibility, before
# any expensive tokens are spent. Intent is cheap and only a human can supply
# it; quality is expensive and only the jury can judge it. Splitting them here
# means cost scales with intent rather than artifact volume.
#
# NOTHING in this file may invoke a model. That is what makes "no tokens spent
# on unselected candidates" a property of the code rather than a promise.
#
# Requires librarian-lesson-storage.sh and librarian-lesson-validate.sh.

librarian_lesson_passed_path() {
	local key="$1"
	printf '%s/passed.jsonl' "$(librarian_lessons_dir "$key")"
}

# Print pending proposals as a JSON array, oldest first. Prints [] when none.
#
# A malformed or racing file must shrink the result, never erase it: a
# truncated write, a bare-value file, or a confirm/pass rewriting the file
# mid-read all read as "that entry is missing" here, not as an error that
# discards every proposal already gathered. `select(type == "object" and
# ...)` folds the parse guard and the pending check into a single read of
# each file, the same shape librarian_lesson_seen uses for the same reason.
#
# Usage: librarian_lesson_list_pending <key>
librarian_lesson_list_pending() {
	local key="$1"
	[[ -z "$key" ]] && { printf '[]'; return 0; }

	local dir
	dir="$(librarian_lessons_dir "$key")/proposals"
	[[ -d "$dir" ]] || { printf '[]'; return 0; }

	local f out entry merged
	out='[]'
	for f in "$dir"/*.json; do
		[[ -f "$f" ]] || continue
		entry=$(jq -c 'select(type == "object" and .status == "pending")' "$f" 2>/dev/null)
		[[ -z "$entry" ]] && continue
		# Merge into a separate variable, not directly into $out: `out=$(cmd)
		# || continue` still assigns $out to cmd's (possibly empty) stdout
		# before the `||` is ever evaluated, so a failed merge would silently
		# wipe everything already gathered even with `continue` guarding it.
		merged=$(jq -c --argjson e "$entry" '. + [$e]' <<<"$out" 2>/dev/null) || continue
		out="$merged"
	done
	printf '%s' "$(jq -c 'sort_by(.created_at)' <<<"$out")"
}

_librarian_lesson_valid_visibility() {
	case "${1:-}" in
		private | org | public) return 0 ;;
		*) return 1 ;;
	esac
}

# Confirm a candidate for the jury.
#
# Usage: librarian_lesson_confirm <key> <lesson_id> <visibility> [justification]
#
# With a justification, the candidate's scope is rewritten to
# version_independent. That branch is refused at private visibility: private
# lessons run no jury, so the justification would reach the pool with nothing
# checking it — the same hole the transform closes by refusing the branch
# outright. Requiring org or public means scope_accuracy actually tests it.
librarian_lesson_confirm() {
	local key="$1"
	local lesson_id="$2"
	local visibility="${3:-}"
	local justification="${4:-}"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	_librarian_lesson_valid_visibility "$visibility" || {
		printf 'visibility must be one of: private, org, public\n' >&2
		return 1
	}

	if [[ -n "$justification" && "$visibility" == "private" ]]; then
		printf 'version_independent requires org or public visibility: a private lesson runs no jury, so its justification would go unchecked and the lesson would never expire\n' >&2
		return 1
	fi

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local proposal candidate current_status
	proposal=$(jq '.' "$path" 2>/dev/null) || return 1
	candidate=$(printf '%s' "$proposal" | jq -c '.candidate' 2>/dev/null) || return 1
	current_status=$(printf '%s' "$proposal" | jq -r '.status // ""' 2>/dev/null)

	if [[ -n "$justification" ]]; then
		candidate=$(printf '%s' "$candidate" | jq -c \
			--arg j "$justification" \
			'.applies_to.scope = {kind: "version_independent", justification: $j}' 2>/dev/null) || return 1
	fi

	# Guard the transition, not just the write. Each write below is already
	# atomic (one merged jq expression, one write), but an unguarded SEQUENCE
	# is where a passed candidate could be flipped back to confirmed while
	# passed.jsonl still asserts the human declined it — the durable record
	# of intent disagreeing with the candidate it describes.
	case "$current_status" in
		pending) ;;
		confirmed)
			# Idempotent only when the repeat asks for exactly what is
			# already recorded; anything else is a contradictory flip.
			if printf '%s' "$proposal" | jq -e \
				--arg v "$visibility" --argjson c "$candidate" \
				'.visibility == $v and .candidate == $c' >/dev/null 2>&1; then
				return 0
			fi
			printf 'Lesson %s is already confirmed; visibility or scope differs from the request.\n' \
				"$lesson_id" >&2
			return 1
			;;
		passed)
			printf 'Lesson %s was passed on; it cannot be confirmed.\n' "$lesson_id" >&2
			return 1
			;;
		*)
			printf 'Lesson %s has an unrecognized status: %s\n' "$lesson_id" "$current_status" >&2
			return 1
			;;
	esac

	librarian_lesson_validate_confirmed "$candidate" 2>/dev/null || {
		printf 'Candidate does not validate; not confirmed.\n' >&2
		return 1
	}

	local now updated
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(printf '%s' "$proposal" | jq \
		--arg v "$visibility" --arg t "$now" --argjson c "$candidate" \
		'. * {status: "confirmed", visibility: $v, confirmed_at: $t, candidate: $c}' 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	printf '%s\n' "$updated" > "$path"
}

# Decline to share a candidate.
#
# The file is KEPT. librarian_lesson_seen scans proposals/ by artifact_id, so
# leaving it in place is what stops the artifact being re-proposed on the next
# scan and re-paying for a transform whose answer the human already gave.
#
# The ledger is separate from declined.jsonl on purpose: that file records
# machine verdicts and feeds rubric tuning, and folding human intent into it
# would corrupt the signal it exists to carry.
#
# Usage: librarian_lesson_pass <key> <lesson_id> [reason]
librarian_lesson_pass() {
	local key="$1"
	local lesson_id="$2"
	local reason="${3:-}"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local current_status
	current_status=$(jq -r '.status // ""' "$path" 2>/dev/null)

	# Same reasoning as confirm: guard the transition. Passing twice must not
	# append a second ledger line, and a confirmed candidate must not be
	# silently un-confirmed — that would leave stale visibility/confirmed_at
	# behind and send a contradictory signal to the stages that select on
	# status downstream.
	case "$current_status" in
		pending) ;;
		passed) return 0 ;;
		confirmed)
			printf 'Lesson %s is confirmed for the jury; it cannot be passed on now.\n' "$lesson_id" >&2
			return 1
			;;
		*)
			printf 'Lesson %s has an unrecognized status: %s\n' "$lesson_id" "$current_status" >&2
			return 1
			;;
	esac

	local artifact_id now updated
	artifact_id=$(jq -r '.artifact_id // ""' "$path" 2>/dev/null)
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	updated=$(jq --arg t "$now" '. * {status: "passed", passed_at: $t}' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	printf '%s\n' "$updated" > "$path"

	local line
	line=$(jq -cn \
		--arg lesson_id "$lesson_id" \
		--arg artifact_id "$artifact_id" \
		--arg reason "$reason" \
		--arg at "$now" \
		'{lesson_id: $lesson_id, artifact_id: $artifact_id,
		  reason: (if $reason == "" then null else $reason end), passed_at: $at}') || return 1

	printf '%s\n' "$line" >> "$(librarian_lesson_passed_path "$key")"
}

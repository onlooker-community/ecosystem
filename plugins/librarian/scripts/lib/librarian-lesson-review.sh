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
# Run a jq filter over every proposal object, oldest first, and print what it
# yields. Each caller's filter receives the whole array, so a caller that needs
# several answers gets them from one read.
#
# A malformed or racing file must shrink the result, never erase it: a
# truncated write, a bare-value file, or a confirm/pass rewriting the file
# mid-read all read as "that entry is missing" here, not as an error that
# discards every proposal already gathered. `select(type == "object")` is the
# parse guard, the same shape librarian_lesson_seen uses for the same reason.
#
# One jq reads every file, because one jq per file cost ~2s at 82 lessons
# (ONL-238). jq reads each file as text and parses it under `try`, since a
# parse error in an input would end the run. The one failure that can't be
# caught there is a file jq can't open, which fails the whole call before the
# filter runs, so that case re-reads file by file.
#
# Output is -r: string results print raw, arrays and numbers are unaffected.
#
# Usage: _librarian_lesson_query <key> <filter> [jq args...]
_librarian_lesson_query() {
	local key="$1" filter="$2"
	shift 2

	local dir=""
	[[ -n "$key" ]] && dir="$(librarian_lessons_dir "$key")/proposals"

	local f n=0 rawfiles=() files=()
	if [[ -n "$dir" && -d "$dir" ]]; then
		for f in "$dir"/*.json; do
			[[ -f "$f" ]] || continue
			files+=("$f")
			rawfiles+=(--rawfile "f${n}" "$f")
			n=$((n + 1))
		done
	fi
	# The filter still runs on an empty set, so a count prints 0 and a list
	# prints [] rather than the caller special-casing nothing.
	[[ "$n" -eq 0 ]] && { jq -rcn "$@" "[] | ${filter}"; return 0; }

	jq -rcn --argjson n "$n" "$@" "${rawfiles[@]}" "
		[range(\$n) as \$i | \$ARGS.named[\"f\\(\$i)\"] | try fromjson catch empty
			| select(type == \"object\")]
		| sort_by(.created_at)
		| ${filter}
	" 2>/dev/null && return 0

	for f in "${files[@]}"; do
		jq -cRs 'try fromjson catch empty | select(type == "object")' "$f" 2>/dev/null
	done | jq -rcs "$@" "sort_by(.created_at) | ${filter}"
}

# Print proposals in the given status as a JSON array, oldest first. Prints []
# when none.
#
# Usage: librarian_lesson_list_by_status <key> <status>
librarian_lesson_list_by_status() {
	local key="$1"
	local status="$2"
	[[ -z "$key" || -z "$status" ]] && { printf '[]'; return 0; }
	_librarian_lesson_query "$key" 'map(select(.status == $s))' --arg s "$status"
}

# Pending is the queue the review walk drives, so it keeps its own name.
#
# Usage: librarian_lesson_list_pending <key>
librarian_lesson_list_pending() {
	librarian_lesson_list_by_status "${1:-}" "pending"
}

# A terminal verdict whose promote() never stamped: the pool entry or declined
# row has not landed, or landed without its stamp. promote() stamps
# promoted_at LAST, so the missing stamp is exactly that state, and a held
# lesson is stamped before it waits out its window, so it is never counted
# here. `lessons promote <id>` reconciles every case.
#
# The filter is data both readers use, `lessons status` through
# librarian_lesson_list_awaiting_promotion and SessionStart through
# librarian_lesson_surface_counts, so the two cannot disagree (ONL-117).
# Approved before rejected, then a stable sort, as the per-status lists it
# replaced produced.
_LIBRARIAN_LESSON_AWAITING_PROMOTION='(map(select(.status == "approved")) + map(select(.status == "rejected")))
	| sort_by(.created_at) | .[] | select(has("promoted_at") | not) | .id'

# Prints the ids, one per line, oldest first.
#
# Usage: librarian_lesson_list_awaiting_promotion <key>
librarian_lesson_list_awaiting_promotion() {
	[[ -z "${1:-}" ]] && return 0
	_librarian_lesson_query "$1" "$_LIBRARIAN_LESSON_AWAITING_PROMOTION"
}

# What SessionStart surfaces, from one read of the proposals: the pending
# count on the first line, then the ids awaiting promotion, one per line.
# SessionStart used to read every proposal three times for these (pending,
# approved, rejected) plus a jq to merge two of them: ~53ms of a ~270ms hook,
# against ~15ms for this (ONL-269).
#
# Usage: librarian_lesson_surface_counts <key>
librarian_lesson_surface_counts() {
	[[ -z "${1:-}" ]] && { printf '0\n'; return 0; }
	_librarian_lesson_query "$1" \
		"(map(select(.status == \"pending\")) | length), (${_LIBRARIAN_LESSON_AWAITING_PROMOTION})"
}

_librarian_lesson_valid_visibility() {
	case "${1:-}" in
		private | org | public) return 0 ;;
		*) return 1 ;;
	esac
}

# Confirm a candidate for the jury.
#
# Usage: librarian_lesson_confirm <key> <lesson_id> <visibility> [justification] [asserted_by]
#
# With a justification, the candidate's scope is rewritten to
# version_independent. That branch is refused at private visibility: private
# lessons run no jury, so the justification would reach the pool with nothing
# checking it — the same hole the transform closes by refusing the branch
# outright. Requiring org or public means scope_accuracy actually tests it.
#
# asserted_by records WHO is vouching for this scope — "human" (default) or
# "model" — so downstream (rubric selection, the promotion hold) can hold a
# model's assertion to a stricter standard than a human's. Anything else is
# refused rather than written through: an unrecognized value here would
# silently fall back to whatever the readers default to, and that default is
# "human" — the least scrutiny, not the most.
librarian_lesson_confirm() {
	local key="$1"
	local lesson_id="$2"
	local visibility="${3:-}"
	local justification="${4:-}"
	local asserted_by="${5:-human}"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	_librarian_lesson_valid_visibility "$visibility" || {
		printf 'visibility must be one of: private, org, public\n' >&2
		return 1
	}

	case "$asserted_by" in
		human | model) ;;
		*)
			printf 'asserted_by must be human or model\n' >&2
			return 1
			;;
	esac

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

	# A parked candidate carries no scope of its own. Confirming it without a
	# justification would write a lesson asserting nothing, which
	# librarian_lesson_validate_confirmed refuses anyway — but it refuses with a
	# bare schema_invalid. Refuse here instead, where the message can say what is
	# actually required.
	if [[ -z "$justification" ]] && printf '%s' "$candidate" \
		| jq -e '.applies_to.scope.kind == "unscoped"' >/dev/null 2>&1; then
		printf 'this lesson has no version scope: confirming it requires a justification (why it holds regardless of version), at org or public visibility so a jury checks the claim\n' >&2
		return 1
	fi

	# Snapshot the candidate before the rewrite, so unconfirm can put it back.
	# Only when we actually rewrite: a plain confirm never touches .candidate,
	# so a snapshot there would be dead weight that unconfirm has to reason
	# about. Absence of the field means "nothing was mutated".
	local candidate_before=""
	if [[ -n "$justification" ]]; then
		candidate_before="$candidate"
		candidate=$(printf '%s' "$candidate" | jq -c \
			--arg j "$justification" \
			'.applies_to.scope = {kind: "version_independent", justification: $j}' 2>/dev/null) || return 1
	fi

	# Authoritative guard: check the RESULTING state, not just this call's
	# input. The check above only catches a justification supplied on THIS
	# invocation; a candidate that already carries version_independent scope
	# (proposed that way, or confirmed non-private earlier and now being
	# reconfirmed at private) would sail past it and write with no jury ever
	# validating the justification. This check is the one that actually holds
	# the invariant — the input check above is only a fast path that avoids
	# reading the file for the common case.
	if [[ "$visibility" == "private" ]] && printf '%s' "$candidate" \
		| jq -e '.applies_to.scope.kind == "version_independent"' >/dev/null 2>&1; then
		printf 'version_independent requires org or public visibility: a private lesson runs no jury, so its justification would go unchecked and the lesson would never expire\n' >&2
		return 1
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
	# `.candidate` is assigned, not merged into with `*`: `*` is a recursive
	# merge, and merging the fresh candidate over the stored one leaves stale
	# keys behind — a version_independent rewrite would keep the old
	# versioned scope's `versions` key alongside the new `justification`,
	# producing a candidate that fails its own validator's
	# additionalProperties check on the way out the door.
	if [[ -n "$candidate_before" ]]; then
		updated=$(printf '%s' "$proposal" | jq \
			--arg v "$visibility" --arg t "$now" --arg ab "$asserted_by" \
			--argjson c "$candidate" --argjson cb "$candidate_before" \
			'. * {status: "confirmed", visibility: $v, confirmed_at: $t}
			 | .candidate = $c
			 | .candidate_before_confirm = $cb
			 | .asserted_by = $ab
			 | del(.auto_hold)' 2>/dev/null) || return 1
	else
		# No rewrite happened, so there is nothing to snapshot — and any field
		# already on the proposal is stale by definition. Deleting it holds the
		# invariant unconfirm relies on ("absence means the candidate was never
		# mutated") from both ends: without this, a proposal that arrives
		# carrying the field keeps it through a plain confirm, and the next
		# unconfirm silently replaces .candidate with a snapshot describing a
		# rewrite this confirm never performed.
		updated=$(printf '%s' "$proposal" | jq \
			--arg v "$visibility" --arg t "$now" --arg ab "$asserted_by" --argjson c "$candidate" \
			'. * {status: "confirmed", visibility: $v, confirmed_at: $t}
			 | .candidate = $c
			 | del(.candidate_before_confirm, .auto_hold)
			 | .asserted_by = $ab' 2>/dev/null) || return 1
	fi
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	librarian_lesson_write_atomic "$path" "$updated"
}

# Hold a pending candidate against the unattended stage (ONL-112).
#
# The stage auto-confirms every parked pending candidate it finds, so a
# person's "not now" or "take that back" left a candidate exactly where the
# next scan would assert it again. .auto_hold is the marker the stage skips.
# It names the verb so `lessons show` can say why the candidate is waiting.
# A human confirm clears it; pass is terminal and needs nothing.
#
# Usage: librarian_lesson_hold <key> <lesson_id> <defer|unconfirm>
librarian_lesson_hold() {
	local key="$1" lesson_id="$2" by="${3:-}"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1
	case "$by" in defer | unconfirm) ;; *) return 1 ;; esac

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local current_status
	current_status=$(jq -r '.status // ""' "$path" 2>/dev/null)
	if [[ "$current_status" != "pending" ]]; then
		if [[ "$current_status" == "confirmed" ]]; then
			printf 'Lesson %s is confirmed, not pending; unconfirm takes it back and holds it.\n' "$lesson_id" >&2
		else
			printf 'Lesson %s is %s, not pending; there is nothing to hold.\n' "$lesson_id" "${current_status:-unreadable}" >&2
		fi
		return 1
	fi

	local now updated
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(jq --arg by "$by" --arg t "$now" '.auto_hold = {by: $by, at: $t}' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	librarian_lesson_write_atomic "$path" "$updated"
}

# Take back a confirmation, before the jury has seen the lesson.
#
# `confirmed` is otherwise terminal: confirm refuses a differing repeat and
# pass refuses a confirmed lesson. Those guards are correct — they are what
# keeps passed.jsonl from contradicting the proposal it describes — but they
# left no way back from confirming at the wrong visibility, and `public` is
# the tier that leaves this machine.
#
# Proceeds ONLY from `confirmed`. Every other status is refused, which is also
# what makes this forward-safe: when the jury stage introduces a status of its
# own, this verb refuses it through the catch-all with no change here.
#
# The lesson it returns to pending is held against the unattended stage, in
# the same write: a person taking a confirmation back has said "not like
# this", and the next scan must not confirm it again on a model's word
# (ONL-112).
#
# Usage: librarian_lesson_unconfirm <key> <lesson_id>
librarian_lesson_unconfirm() {
	local key="$1"
	local lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && return 1

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local current_status
	current_status=$(jq -r '.status // ""' "$path" 2>/dev/null)

	case "$current_status" in
		confirmed) ;;
		pending) return 0 ;;
		passed)
			# Passing is a different decision with its own durable record.
			# Silently moving it back to pending would leave passed.jsonl
			# asserting a decision the proposal contradicts.
			printf 'Lesson %s was passed on, not confirmed; unconfirm does not undo that.\n' "$lesson_id" >&2
			return 1
			;;
		*)
			printf 'Lesson %s has an unrecognized status: %s\n' "$lesson_id" "$current_status" >&2
			return 1
			;;
	esac

	# Restore the pre-confirm candidate when one was snapshotted, and delete
	# the snapshot either way. A stale snapshot left on a pending proposal is
	# indistinguishable from a live one at the next confirm, and would
	# silently revert a later legitimate rewrite. asserted_by is confirm-only
	# state too — a pending proposal never carries it — so it comes off here
	# for the same reason: leaving it behind would make a pending lesson
	# reached only through unconfirm indistinguishable from one that was
	# always pending.
	local updated
	local now
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(jq --arg t "$now" '
		(if has("candidate_before_confirm") then .candidate = .candidate_before_confirm else . end)
		| del(.candidate_before_confirm, .visibility, .confirmed_at, .asserted_by)
		| .status = "pending"
		| .auto_hold = {by: "unconfirm", at: $t}
	' "$path" 2>/dev/null) || return 1
	[[ -z "$updated" || "$updated" == "null" ]] && return 1
	librarian_lesson_write_atomic "$path" "$updated"
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
	librarian_lesson_write_atomic "$path" "$updated" || return 1

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

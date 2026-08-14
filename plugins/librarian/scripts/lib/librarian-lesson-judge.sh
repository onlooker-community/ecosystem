#!/usr/bin/env bash
# Aggregate, gate, and record a jury verdict on a confirmed lesson.
#
# The agent orchestrates the jury; this file decides. Everything except
# subagent dispatch lives here so it can be tested.
#
# Librarian implements its own aggregate and gate rather than sourcing
# tribunal's. Reusing tribunal's published AGENT definitions is licensed by
# docs/adr/002-agent-definitions-are-shared-assets.md; sourcing its bash would
# be the hook-to-hook runtime coupling that ADR rules out.
#
# Exposes:
#   librarian_lesson_aggregate <verdicts_json> [<rubric_json>]
#   librarian_lesson_gate <gate_policy> <verdicts_json> <aggregate> <threshold> [<rubric_json>]
#   librarian_lesson_judge <key> <lesson_id> <verdicts_json>

# Aggregate the judges' scores. Returns 1 on an empty panel.
#
# With a rubric and per-criterion scores, this is a weighted mean: average the
# judges on each criterion, weight each criterion's mean, normalize by the
# weights actually used. Without them it is the plain mean it has always been.
#
# A criterion no judge scored contributes nothing and its weight leaves the
# denominator — absence is not a zero. Scoring it 0 instead would turn a judge
# that skipped a criterion into one that failed it.
#
# Usage: librarian_lesson_aggregate <verdicts_json> [<rubric_json>]
librarian_lesson_aggregate() {
	local verdicts="${1:-[]}"
	local rubric="${2:-}"
	[ -z "$rubric" ] && rubric='{}'

	local n
	n=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || return 1
	[[ -z "$n" || "$n" -eq 0 ]] && return 1

	local weighted
	weighted=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
		. as $v
		| [ ($rubric.criteria // [])[]
		    | select((.name | type) == "string" and (.weight | type) == "number")
		    | . as $c
		    | ([ $v[]
		         | select((.criterion_scores | type) == "object")
		         | select(.criterion_scores | has($c.name))
		         | .criterion_scores[$c.name]
		         | select(type == "number") ]) as $scores
		    | select(($scores | length) > 0)
		    | { w: $c.weight, m: (($scores | add) / ($scores | length)) } ]
		| (map(.w) | add) as $den
		| if length == 0 or $den == null or $den <= 0 then empty
		  else (map(.w * .m) | add) / $den
		  end
	' 2>/dev/null)
	if [ -n "$weighted" ]; then
		printf '%s' "$weighted"
		return 0
	fi

	printf '%s' "$verdicts" | jq -r '[.[].score] | add / length' 2>/dev/null || return 1
}

# Decide pass/block from the panel, the aggregate, and the rubric's floors.
#
# Echoes {"passed": bool, "reason": string} and, when a floor was violated, a
# "failed_criterion" naming it — on whichever blocking reason wins, not only on
# `criterion_floor`. Three conditions must hold: the jury clears its policy, the
# aggregate clears the threshold, and no criterion sits below its min_pass.
#
# The floor is what makes the public tier meaningfully stricter than org. Before
# it existed, lesson-promotion-public declared gate_policy `unanimous` for that
# purpose and it did nothing at all — see ecosystem-j74.
#
# Usage: librarian_lesson_gate <gate_policy> <verdicts_json> <aggregate> <threshold> [<rubric_json>]
librarian_lesson_gate() {
	local policy="${1:-majority}"
	local verdicts="${2:-[]}"
	local aggregate="${3:-0}"
	local threshold="${4:-0.75}"
	local rubric="${5:-}"
	[ -z "$rubric" ] && rubric='{}'

	local count passed_count
	count=$(printf '%s' "$verdicts" | jq 'length' 2>/dev/null) || count=0
	passed_count=$(printf '%s' "$verdicts" | jq '[.[] | select(.passed == true)] | length' 2>/dev/null) || passed_count=0

	# Per-criterion floors, computed up front. The precedence below is unchanged
	# — jury, then aggregate, then floor — but a violated floor now names itself
	# on whichever reason wins. `disclosure` carries weight 0.30, so the *worst*
	# leaks drag the aggregate under the threshold and used to land as a bare
	# `below_threshold`, while borderline ones got named: the diagnostic was
	# absent exactly where it mattered most.
	#
	# The floor is the *lowest* score among the judges that scored it, not their
	# mean. A floor means nobody may be below it; using the mean let one judge's
	# finding be diluted by others who did not look, and made every floor weaker
	# as the panel grew. Weighting still uses the mean — only the floor is a
	# minimum.
	#
	# A criterion no judge scored is not a violation here: absence is not a zero.
	# librarian_lesson_judge refuses that panel outright before it reaches this
	# function, which is the stronger answer than silently skipping the floor.
	local floor_failed
	floor_failed=$(printf '%s' "$verdicts" | jq -r --argjson rubric "$rubric" '
		. as $v
		| [ ($rubric.criteria // [])[]
		    | select((.name | type) == "string" and (.min_pass | type) == "number")
		    | . as $c
		    | ([ $v[]
		         | select((.criterion_scores | type) == "object")
		         | select(.criterion_scores | has($c.name))
		         | .criterion_scores[$c.name]
		         | select(type == "number") ]) as $scores
		    | select(($scores | length) > 0)
		    | select(($scores | min) < $c.min_pass)
		    | $c.name ]
		| first // empty
	' 2>/dev/null) || floor_failed=""

	local floor_suffix=""
	[[ -n "$floor_failed" ]] && floor_suffix=$(printf ',"failed_criterion":"%s"' "$floor_failed")

	local jury_ok=1 jury_reason=""
	case "$policy" in
		unanimous)
			if [[ "$count" -gt 0 && "$passed_count" -eq "$count" ]]; then
				jury_ok=0
			else
				jury_reason="jury_not_unanimous"
			fi
			;;
		majority)
			if [[ "$count" -gt 0 ]] && (( passed_count * 2 > count )); then
				jury_ok=0
			else
				jury_reason="jury_not_majority"
			fi
			;;
		*)
			printf '{"passed":false,"reason":"unknown_gate_policy"%s}' "$floor_suffix"
			return 0
			;;
	esac

	if [[ "$jury_ok" -ne 0 ]]; then
		printf '{"passed":false,"reason":"%s"%s}' "$jury_reason" "$floor_suffix"
		return 0
	fi

	# awk for the float comparison: bash cannot compare decimals.
	if ! awk -v s="$aggregate" -v t="$threshold" 'BEGIN { exit !(s >= t) }'; then
		printf '{"passed":false,"reason":"below_threshold"%s}' "$floor_suffix"
		return 0
	fi

	if [[ -n "$floor_failed" ]]; then
		printf '{"passed":false,"reason":"criterion_floor","failed_criterion":"%s"}' "$floor_failed"
		return 0
	fi

	printf '{"passed":true,"reason":"gate_passed"}'
	return 0
}

# Names the floored criteria this panel failed to score, plus a coverage verdict.
#
# Echoes a JSON object: { unscored: [names], covered: <fraction 0..1> }
#
# Librarian refuses rather than degrades. Tribunal can afford to fall back to a
# plain mean because a blocked task retries; a lesson that publishes without its
# `disclosure` floor ever running is not recoverable. "The panel did not evaluate
# the thing that gates this tier" is not a verdict — it is UNJUDGED.
#
# Usage: librarian_lesson_coverage <verdicts_json> <rubric_json>
librarian_lesson_coverage() {
	local verdicts="${1:-[]}"
	# Brace-free default, matching the two functions above: `${2:-{\}}` keeps the
	# backslash on the bash 3.2 macOS ships, yielding `{\}` — invalid JSON, so
	# jq fails and every panel reads as zero coverage. See
	# test/bats/emit-payload-default.bats.
	local rubric="${2:-}"
	[ -z "$rubric" ] && rubric='{}'
	printf '%s' "$verdicts" | jq -c --argjson rubric "$rubric" '
		. as $v
		| ([ ($rubric.criteria // [])[]
		     | select((.weight | type) == "number") | .weight ] | add) as $total_w
		| [ ($rubric.criteria // [])[]
		    | select((.name | type) == "string")
		    | . as $c
		    | { name: $c.name,
		        w: (if (.weight | type) == "number" then .weight else 0 end),
		        floored: ((.min_pass | type) == "number"),
		        n: ([ $v[]
		              | select((.criterion_scores | type) == "object")
		              | select(.criterion_scores | has($c.name))
		              | .criterion_scores[$c.name]
		              | select(type == "number" and . >= 0 and . <= 1) ] | length) } ]
		| { unscored: [ .[] | select(.floored and .n == 0) | .name ],
		    covered: (if $total_w == null or $total_w <= 0 then 0
		              else (([ .[] | select(.n > 0) | .w ] | add) // 0) / $total_w end) }
	' 2>/dev/null || printf '{"unscored":[],"covered":0}'
}

# Judge one confirmed lesson and record the outcome.
#
# Return codes are the interface the CLI and skill depend on:
#   0  a verdict was recorded (status is now approved or rejected)
#   1  usage or state error; nothing written
#   2  UNJUDGED — the panel was unusable; nothing written, lesson stays
#      confirmed, and the next run retries it
#
# 2 is not a failure. "Judged and failed" must stay distinct from "could not
# judge": the watermark has already advanced past this artifact, so treating a
# broken judge as a rejection would bury a good lesson permanently.
#
# Usage: librarian_lesson_judge <key> <lesson_id> <verdicts_json>
librarian_lesson_judge() {
	local key="$1"
	local lesson_id="$2"
	local verdicts="${3:-[]}"
	if [[ -z "$key" || -z "$lesson_id" ]]; then
		printf 'usage: librarian_lesson_judge <key> <lesson_id> <verdicts_json>\n' >&2
		return 1
	fi

	local path
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'Lesson %s not found.\n' "$lesson_id" >&2; return 1; }

	local current_status visibility
	current_status=$(jq -r '.status // ""' "$path" 2>/dev/null)
	visibility=$(jq -r '.visibility // ""' "$path" 2>/dev/null)

	if [[ "$current_status" != "confirmed" ]]; then
		printf 'Lesson %s is not confirmed; its status is: %s\n' "$lesson_id" "$current_status" >&2
		return 1
	fi

	local rubric_id
	rubric_id=$(librarian_lesson_rubric_id_for_visibility "$visibility") || {
		printf 'Lesson %s has an unrecognized visibility: %s\n' "$lesson_id" "$visibility" >&2
		return 1
	}

	local verdict now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

	if [[ -z "$rubric_id" ]]; then
		# private: no jury, no model call, straight through.
		verdict=$(jq -cn --arg t "$now" \
			'{rubric_id: null, gate_policy: null, score_threshold: null,
			  aggregate_score: null, passed: true, reason: "private_no_jury",
			  judges: []}') || {
			printf 'Lesson %s: the verdict could not be built.\n' "$lesson_id" >&2
			return 1
		}
	else
		local rubric threshold policy expected_judge_types
		rubric=$(librarian_lesson_rubric_get "$rubric_id") || {
			printf 'Lesson %s: rubric %s is not defined in config.\n' "$lesson_id" "$rubric_id" >&2
			return 1
		}
		threshold=$(printf '%s' "$rubric" | jq -r '.score_threshold')
		policy=$(printf '%s' "$rubric" | jq -r '.gate_policy')
		expected_judge_types=$(printf '%s' "$rubric" | jq -c '.judge_types | sort')

		# Every judge must have returned a usable verdict AND the panel's
		# multiset of judge_type values must exactly match the rubric's
		# judge_types, or this candidate is unjudged. Checking element types
		# alone is not enough: a one-element panel is trivially unanimous, so
		# a lone approving judge would promote a public lesson on its own,
		# and two judges of the same type could silently stand in for a
		# missing one. With a two-judge panel under either policy, losing (or
		# duplicating) one verdict means the gate cannot be honestly decided.
		local usable
		usable=$(printf '%s' "$verdicts" | jq --argjson want "$expected_judge_types" '
			if type != "array" or length == 0 then false
			else (all(.[]; (.judge_type | type) == "string"
			              and (.score | type) == "number"
			              and (.passed | type) == "boolean")
			      and ([.[].judge_type] | sort) == $want)
			end' 2>/dev/null) || usable="false"
		[[ "$usable" != "true" ]] && return 2

		# A floored criterion nobody scored, or a panel that covered too little
		# of the rubric, is UNJUDGED — not a pass. The candidate stays
		# `confirmed` and the next run retries it.
		local coverage unscored covered min_coverage
		min_coverage=$(librarian_config_get '.librarian.lesson_judging.min_criterion_coverage' 2>/dev/null)
		case "$min_coverage" in
			''|null) min_coverage="0.6" ;;
		esac
		coverage=$(librarian_lesson_coverage "$verdicts" "$rubric")
		unscored=$(printf '%s' "$coverage" | jq -r '.unscored | join(", ")')
		covered=$(printf '%s' "$coverage" | jq -r '.covered')
		if [[ -n "$unscored" ]]; then
			printf 'Lesson %s: no judge scored these floored criteria, so the panel cannot be trusted: %s\n' \
				"$lesson_id" "$unscored" >&2
			return 2
		fi
		if ! awk -v c="$covered" -v m="$min_coverage" 'BEGIN { exit !(c >= m) }'; then
			printf 'Lesson %s: the panel scored only %s of the rubric weight (minimum %s).\n' \
				"$lesson_id" "$covered" "$min_coverage" >&2
			return 2
		fi

		local aggregate gate
		aggregate=$(librarian_lesson_aggregate "$verdicts" "$rubric") || return 2
		gate=$(librarian_lesson_gate "$policy" "$verdicts" "$aggregate" "$threshold" "$rubric") || {
			printf 'Lesson %s: the gate could not be decided.\n' "$lesson_id" >&2
			return 1
		}

		verdict=$(jq -cn \
			--arg r "$rubric_id" --arg p "$policy" \
			--argjson th "$threshold" --argjson ag "$aggregate" \
			--argjson g "$gate" --argjson j "$verdicts" \
			'{rubric_id: $r, gate_policy: $p, score_threshold: $th,
			  aggregate_score: $ag, passed: $g.passed, reason: $g.reason,
			  judges: $j}
			 + (if $g.failed_criterion then {failed_criterion: $g.failed_criterion} else {} end)') || {
			printf 'Lesson %s: the verdict could not be built.\n' "$lesson_id" >&2
			return 1
		}
	fi

	local new_status updated
	if [[ "$(printf '%s' "$verdict" | jq -r '.passed')" == "true" ]]; then
		new_status="approved"
	else
		new_status="rejected"
	fi

	updated=$(jq --arg s "$new_status" --arg t "$now" --argjson v "$verdict" \
		'.status = $s | .judged_at = $t | .verdict = $v' "$path" 2>/dev/null) || {
		printf 'Lesson %s: the verdict could not be recorded.\n' "$lesson_id" >&2
		return 1
	}
	if [[ -z "$updated" || "$updated" == "null" ]]; then
		printf 'Lesson %s: the verdict could not be recorded; the update produced no result.\n' "$lesson_id" >&2
		return 1
	fi
	# Atomic, not `printf > "$path"`: a plain redirect truncates before
	# writing, so an interrupted write here leaves the same zero-byte,
	# permanently-stuck proposal that a3b fixed in confirm, unconfirm, and
	# pass — "unrecognized status: " from every verb, and even unconfirm
	# cannot recover it because list_pending hides it too.
	librarian_lesson_write_atomic "$path" "$updated"
}

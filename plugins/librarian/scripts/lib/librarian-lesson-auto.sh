#!/usr/bin/env bash
# Unattended lesson promotion: the model supplies the version-independence
# justification, and the jury runs with nobody present.
#
# Everything here makes LLM calls, so it runs ONLY from the detached classify
# worker — never on the SessionEnd path (ADR-003).
#
# The trust boundary is unchanged from the attended path. The transform still
# emits scope {kind: unscoped}; this file calls the same
# librarian_lesson_confirm a human's walk calls, and records asserted_by so the
# assertion is judged harder (librarian_lesson_rubric_id_for_visibility) and
# held longer (librarian_lesson_promote).

# Ask for one sentence saying why the claim holds regardless of version, or a
# refusal. A refusal is a real answer and leaves the candidate for a human.
#
# The two prohibitions in the prompt are the defects ONL-110 records, which are
# exactly what the adversarial judge attacks: asserting one remedy is required
# when others exist, and claiming anything the cited evidence does not show.
#
# Usage: librarian_lesson_auto_justify <candidate_json> [model]
librarian_lesson_auto_justify() {
	local candidate="$1"
	local model="${2:-}"
	[[ -z "$candidate" ]] && return 0
	command -v claude >/dev/null 2>&1 || return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-auto.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-auto.$$"
	# shellcheck disable=SC2064
	trap "rm -f '$prompt_file'" EXIT

	{
		printf '%s\n' 'You are deciding whether a lesson holds regardless of version.'
		printf '%s\n\n' 'Output ONE sentence, or exactly REFUSE. No markdown, no preamble.'
		printf '%s\n' 'Say REFUSE unless the claim is true independent of any version of any'
		printf '%s\n\n' 'tool named in its stack.'
		printf '%s\n' 'Two things make a justification wrong, and both are refusals:'
		printf '%s\n' '- asserting one remedy is required when other standard remedies exist'
		printf '%s\n\n' '- claiming anything the cited evidence does not actually show'
		printf '%s\n' 'Write why this lesson holds regardless of version:'
		printf '%s\n' '<candidate>'
		printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nrationale: \(.rationale)\nresolution: \(.evidence.resolution)\nstack: \(.applies_to.stack | join(", "))"' 2>/dev/null
		printf '%s\n' '</candidate>'
	} > "$prompt_file" || { rm -f "$prompt_file"; trap - EXIT; return 0; }

	local args=(-p --max-turns 1)
	[[ -n "$model" ]] && args+=(--model "$model")

	local timeout_seconds response=""
	timeout_seconds=$(librarian_config_get '.librarian.lesson_transform.timeout_seconds' 2>/dev/null)
	case "$timeout_seconds" in ''|null) timeout_seconds=120 ;; esac

	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$timeout_seconds" claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$timeout_seconds" claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi

	rm -f "$prompt_file"
	trap - EXIT

	# Collapse to one line and trim: a justification is a single sentence, and
	# a stray newline would corrupt the envelope's shape.
	printf '%s' "$response" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Auto-confirm one parked candidate. Prints exactly one of:
#   confirmed:<id>             model asserted a scope; now awaiting a jury
#   skipped:not_parked         scope is not unscoped; nothing to assert
#   skipped:no_justification   the model refused; left pending for a human
#   unavailable                infrastructure; nothing written
#
# Usage: librarian_lesson_auto_confirm_one <key> <lesson_id>
librarian_lesson_auto_confirm_one() {
	local key="$1"
	local lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && { printf 'unavailable'; return 0; }

	local path candidate
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'unavailable'; return 0; }
	candidate=$(jq -c '.candidate' "$path" 2>/dev/null) || { printf 'unavailable'; return 0; }

	if ! printf '%s' "$candidate" | jq -e '.applies_to.scope.kind == "unscoped"' >/dev/null 2>&1; then
		printf 'skipped:not_parked'
		return 0
	fi

	local model justification
	model=$(librarian_config_get '.librarian.lesson_transform.model' 2>/dev/null)
	justification=$(librarian_lesson_auto_justify "$candidate" "$model")

	# Empty is infrastructure, not a verdict — the same distinction
	# librarian_lesson_transform_one draws. Leave the artifact untouched.
	[[ -z "$justification" ]] && { printf 'unavailable'; return 0; }
	if [[ "$justification" == REFUSE* ]]; then
		printf 'skipped:no_justification'
		return 0
	fi

	local visibility
	visibility=$(librarian_config_get '.librarian.lesson_auto.visibility' 2>/dev/null)
	case "$visibility" in ''|null) visibility="org" ;; esac

	librarian_lesson_confirm "$key" "$lesson_id" "$visibility" "$justification" model \
		>/dev/null 2>&1 || { printf 'unavailable'; return 0; }
	printf 'confirmed:%s' "$lesson_id"
}

# Dispatch one judge by NAME and print its raw verdict JSON.
#
# `claude -p --agent <name>` resolves a plugin-provided agent, which is what
# lets an unattended jury reuse tribunal's published definitions instead of
# inlining copies of their prompts. ADR-002 forbids sourcing anything under
# plugins/tribunal/ — dispatching by name is explicitly allowed, and this is
# the bash equivalent of the Task-tool dispatch the skill walk performs.
#
# Usage: _librarian_lesson_auto_judge <agent_name> <prompt> [model]
_librarian_lesson_auto_judge() {
	local agent="$1" prompt="$2" model="${3:-}"
	command -v claude >/dev/null 2>&1 || return 0

	local args=(-p --max-turns 1 --agent "$agent")
	[[ -n "$model" ]] && args+=(--model "$model")

	local timeout_seconds response=""
	timeout_seconds=$(librarian_config_get '.librarian.lesson_transform.timeout_seconds' 2>/dev/null)
	case "$timeout_seconds" in ''|null) timeout_seconds=120 ;; esac

	if command -v timeout >/dev/null 2>&1; then
		response=$(printf '%s' "$prompt" | timeout "$timeout_seconds" claude "${args[@]}" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(printf '%s' "$prompt" | gtimeout "$timeout_seconds" claude "${args[@]}" 2>/dev/null) || response=""
	else
		response=$(printf '%s' "$prompt" | claude "${args[@]}" 2>/dev/null) || response=""
	fi

	# Reuse the transform's prose-tolerant extractor: a judge that wrapped its
	# JSON in a sentence is a formatting slip, not a refusal.
	_librarian_lesson_extract_json_object "$response" 2>/dev/null
}

# Judge one confirmed candidate with both judges and record the verdict.
# Prints judged:<id>, skipped:unjudged, or unavailable.
#
# Usage: librarian_lesson_auto_judge_one <key> <lesson_id>
librarian_lesson_auto_judge_one() {
	local key="$1" lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && { printf 'unavailable'; return 0; }

	local path candidate visibility rubric_id rubric
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { printf 'unavailable'; return 0; }
	candidate=$(jq -c '.candidate' "$path" 2>/dev/null) || { printf 'unavailable'; return 0; }
	visibility=$(jq -r '.visibility // ""' "$path" 2>/dev/null)
	rubric_id=$(librarian_lesson_rubric_id_for_visibility "$visibility" model) || { printf 'unavailable'; return 0; }
	[[ -z "$rubric_id" ]] && { printf 'unavailable'; return 0; }
	rubric=$(librarian_lesson_rubric_get "$rubric_id") || { printf 'unavailable'; return 0; }

	# Every floored criterion must be scored by SOME judge or the panel is
	# UNJUDGED, so the prompt names them all and says why omitting one is worse
	# than scoring it badly.
	local criteria prompt model
	criteria=$(printf '%s' "$rubric" | jq -r \
		'[.criteria[] | "- \(.name) (weight \(.weight), min_pass \(.min_pass))"] | join("\n")')
	model=$(librarian_config_get '.librarian.lesson_auto.judge_model' 2>/dev/null)
	case "$model" in ''|null) model="claude-haiku-4-5-20251001" ;; esac

	prompt=$(printf '%s\n%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s\n' \
		'Score this lesson candidate for promotion to the shared lesson pool.' \
		'A MODEL asserted that this lesson holds regardless of version; judge that assertion.' \
		'CANDIDATE' \
		"$(printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nrationale: \(.rationale)\nresolution: \(.evidence.resolution)\napplies_to: \(.applies_to | tojson)"')" \
		'RUBRIC — you MUST return a score in [0,1] for EVERY criterion listed. Omitting one makes the whole panel UNJUDGED and the candidate is re-judged at full cost, so an omission prevents a verdict rather than softening it. If you cannot assess one, say so and score your honest worst case.' \
		"$criteria" \
		'Return EXACTLY one JSON object as your final message, no prose around it:' \
		'{"score": <0..1>, "passed": <true|false>, "judge_type": "standard|adversarial", "feedback_summary": "<why>", "criterion_scores": {<each criterion>: <0..1>}}')

	local std adv verdicts
	std=$(_librarian_lesson_auto_judge tribunal-judge-standard "$prompt" "$model")
	adv=$(_librarian_lesson_auto_judge tribunal-judge-adversarial "$prompt" "$model")
	[[ -z "$std" || -z "$adv" ]] && { printf 'unavailable'; return 0; }

	# Stamp judge_type from the dispatched agent name rather than trusting the
	# model's self-report inside the verdict JSON. We already know which agent
	# we called; librarian_lesson_judge checks the panel's judge_type multiset
	# against the rubric's judge_types EXACTLY, so one slip in the model's own
	# output (echoing the "standard|adversarial" literal from the prompt
	# template, or both agents answering "standard") makes the panel
	# permanently UNJUDGED — the candidate stays confirmed and both agent
	# calls are re-billed every later scan, forever, with no backoff. Only
	# this one field is overwritten; every other field in each verdict passes
	# through verbatim.
	std=$(printf '%s' "$std" | jq -c '.judge_type = "standard"' 2>/dev/null) \
		|| { printf 'unavailable'; return 0; }
	adv=$(printf '%s' "$adv" | jq -c '.judge_type = "adversarial"' 2>/dev/null) \
		|| { printf 'unavailable'; return 0; }

	verdicts=$(jq -cn --argjson a "$std" --argjson b "$adv" '[$a, $b]' 2>/dev/null) \
		|| { printf 'unavailable'; return 0; }

	librarian_lesson_judge "$key" "$lesson_id" "$verdicts" >/dev/null 2>&1
	local rc=$?
	case "$rc" in
		0) librarian_lesson_promote "$key" "$lesson_id" >/dev/null 2>&1 || true
		   printf 'judged:%s' "$lesson_id" ;;
		2) printf 'skipped:unjudged' ;;
		*) printf 'unavailable' ;;
	esac
}

# Auto-confirm every parked candidate, then jury as many as the cap allows.
# A no-op unless lesson_auto.enabled is true.
#
# Usage: librarian_lesson_auto_stage <key>
librarian_lesson_auto_stage() {
	local key="$1"
	[[ -z "$key" ]] && return 0

	local enabled
	enabled=$(librarian_config_get '.librarian.lesson_auto.enabled' 2>/dev/null)
	[[ "$enabled" != "true" ]] && return 0

	local cap
	cap=$(librarian_config_get '.librarian.lesson_auto.max_juries_per_scan' 2>/dev/null)
	case "$cap" in ''|null) cap=1 ;; esac

	local id
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		librarian_lesson_auto_confirm_one "$key" "$id" >/dev/null
	done < <(librarian_lesson_list_pending "$key" | jq -r '.[].id' 2>/dev/null)

	# The jury is the expensive step, so it is capped. An over-cap candidate
	# stays `confirmed` and is judged on the next scan — never declined, since
	# a decline is terminal.
	#
	# Filtered to asserted_by == "model" ONLY. `confirmed` is the same queue
	# the attended `/librarian lessons judge` walk reads, and its SKILL.md
	# makes "never dispatch judges without reporting the batch and getting the
	# user's go-ahead" a hard invariant — a human-confirmed candidate can sit
	# `confirmed` across sessions on purpose, waiting on that go-ahead. Without
	# this filter, an unattended run would jury it anyway, and because a
	# human-asserted pass is not held (unlike a model-asserted one), it would
	# land straight in approved/ — the live sync directory — with no veto
	# window at all. Read the envelope's asserted_by, not the candidate's
	# scope kind: version_independent is reachable from both a human's
	# justification and a model's, and would not tell them apart.
	local juried=0
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		[[ "$juried" -ge "$cap" ]] && break
		local proposal_path asserted_by
		proposal_path="$(librarian_lessons_dir "$key")/proposals/${id}.json"
		asserted_by=$(jq -r '.asserted_by // "human"' "$proposal_path" 2>/dev/null)
		[[ "$asserted_by" != "model" ]] && continue
		librarian_lesson_auto_judge_one "$key" "$id" >/dev/null
		juried=$((juried + 1))
	done < <(librarian_lesson_list_by_status "$key" confirmed | jq -r '.[].id' 2>/dev/null)

	return 0
}

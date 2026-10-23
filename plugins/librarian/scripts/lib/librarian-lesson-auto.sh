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
# refusal with one sentence saying why not. A refusal is a real answer and
# leaves the candidate for a human; its reason is what lets that human, and the
# false-refusal measurement, tell a correct refusal from a wrong one (ONL-183).
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
	# No EXIT trap for this file. Called directly rather than through $(...), a
	# trap here replaces the caller's and the `trap - EXIT` after it clears it
	# outright, and the classify worker's EXIT trap is what releases its queue
	# lock (ONL-118). Every path out removes the file itself; a killed call
	# leaks one small file under $TMPDIR, which costs nothing next to a lock
	# that blocks its queue for good.

	{
		printf '%s\n' 'You are deciding whether a lesson holds regardless of version.'
		printf '%s\n' 'Output ONE sentence, or REFUSE: followed by ONE sentence saying why.'
		printf '%s\n\n' 'No markdown, no preamble.'
		printf '%s\n' 'Refuse unless the claim is true independent of any version of any'
		printf '%s\n\n' 'tool named in its stack.'
		printf '%s\n' 'Two things make a justification wrong, and both are refusals:'
		printf '%s\n' '- asserting one remedy is required when other standard remedies exist'
		printf '%s\n\n' '- claiming anything the cited evidence does not actually show'
		printf '%s\n' 'Write why this lesson holds regardless of version:'
		printf '%s\n' '<candidate>'
		printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nrationale: \(.rationale)\nresolution: \(.evidence.resolution)\nstack: \(.applies_to.stack | join(", "))"' 2>/dev/null
		printf '%s\n' '</candidate>'
	} > "$prompt_file" || { rm -f "$prompt_file"; return 0; }

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

	# Collapse to one line and trim: a justification is a single sentence, and
	# a stray newline would corrupt the envelope's shape.
	printf '%s' "$response" | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Record a refusal on the proposal so the review walk can show why the model
# declined. `REFUSE: <reason>` keeps the reason; a bare `REFUSE` is still
# recorded, with reason null, so "refused without saying why" stays
# distinguishable from "never asked".
#
# Deliberately NOT a decline: a decline is terminal, and a refused candidate
# belongs to a human. A later refusal overwrites the earlier one. Best effort --
# a failed write must not turn a real refusal into a different outcome.
#
# Usage: _librarian_lesson_auto_record_refusal <proposal_path> <response>
_librarian_lesson_auto_record_refusal() {
	local path="$1" response="$2"
	local reason now updated
	reason=$(printf '%s' "$response" | sed -E 's/^REFUSE[[:space:]]*:?[[:space:]]*//')
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(jq --arg r "$reason" --arg at "$now" \
		'.auto_refusal = {reason: (if $r == "" then null else $r end), refused_at: $at}' \
		"$path" 2>/dev/null) || return 0
	librarian_lesson_write_atomic "$path" "$updated" >/dev/null 2>&1 || true
}

# Auto-confirm one parked candidate. Prints exactly one of:
#   confirmed:<id>             model asserted a scope; now awaiting a jury
#   skipped:not_parked         scope is not unscoped; nothing to assert
#   skipped:no_justification   the model refused; left pending for a human,
#                              with the refusal recorded as .auto_refusal
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
		_librarian_lesson_auto_record_refusal "$path" "$justification"
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

# Turns allowed to a dispatched judge (ONL-168).
#
# NOT 1. tribunal-judge-standard holds Read/Grep/Glob and the adversarial judge
# also holds Bash, so a judge handed a candidate that cites artifact_ids and a
# project_key spends its turns hunting that evidence on disk and never reaches a
# final message. Measured on a real 1708-byte candidate against
# claude-haiku-4-5-20251001: `--max-turns 1` answered `Reached max turns (1)`
# and `--max-turns 8` answered `Reached max turns (8)` — raising the ceiling
# alone does not fix it, because an exploring judge will spend whatever it is
# given. What fixes it is telling the judge the candidate is self-contained
# (librarian_lesson_auto_judge_prompt does), after which 2 turns returned a
# full four-criterion verdict in 40s.
#
# 4 is that working value plus headroom for one stray tool call, not a tuning
# knob: a higher number cannot rescue a judge that has decided to go reading,
# and the instruction is what keeps it from deciding that. A trivial prompt
# needing no tools DOES answer in one turn, which is why this dispatch looked
# correct in isolation and failed on every real candidate.
_LIBRARIAN_LESSON_JUDGE_MAX_TURNS=4

# Dispatch one judge by NAME and print its raw verdict JSON.
#
# `claude -p --agent <name>` resolves a plugin-provided agent, which is what
# lets an unattended jury reuse tribunal's published definitions instead of
# inlining copies of their prompts. ADR-002 forbids sourcing anything under
# plugins/tribunal/ — dispatching by name is explicitly allowed, and this is
# the bash equivalent of the Task-tool dispatch the skill walk performs.
#
# NOT equivalent in one respect that matters: the attended walk's judges have
# the repo, these do not. See ONL-168 before assuming a verdict from here
# matches one from there.
#
# Usage: _librarian_lesson_auto_judge <agent_name> <prompt> [model]
_librarian_lesson_auto_judge() {
	local agent="$1" prompt="$2" model="${3:-}"
	command -v claude >/dev/null 2>&1 || return 0

	local args=(-p --max-turns "$_LIBRARIAN_LESSON_JUDGE_MAX_TURNS" --agent "$agent")
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

# Build the judge prompt for one candidate against one rubric.
#
# Extracted from librarian_lesson_auto_judge_one so the measurement harness
# (scripts/measure-lesson-transform.sh) scores candidates against the SAME text
# production dispatches. A harness carrying its own copy would measure a prompt
# nobody runs, and would keep reporting the old pass rates after this one is
# changed — which is precisely what ONL-110's children set out to change.
# test/bats/librarian-lesson-auto.bats pins the two together by diffing the
# dispatched stdin against this function's output.
#
# Every floored criterion must be scored by SOME judge or the panel is
# UNJUDGED, so the prompt names them all and says why omitting one is worse
# than scoring it badly.
#
# Usage: librarian_lesson_auto_judge_prompt <candidate_json> <rubric_json>
librarian_lesson_auto_judge_prompt() {
	local candidate="${1:-}" rubric="${2:-}"
	[[ -z "$candidate" || -z "$rubric" ]] && return 0

	local criteria
	criteria=$(librarian_lesson_rubric_render_criteria "$rubric") || return 0

	printf '%s\n%s\n\n%s\n%s\n\n%s\n\n%s\n%s\n\n%s\n%s\n' \
		'Score this lesson candidate for promotion to the shared lesson pool.' \
		'A MODEL asserted that this lesson holds regardless of version; judge that assertion.' \
		'CANDIDATE' \
		"$(printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nrationale: \(.rationale)\nresolution: \(.evidence.resolution)\napplies_to: \(.applies_to | tojson)"')" \
		'The candidate above is self-contained. Do NOT use any tools; do not read files or search a repository. Score from the candidate text alone. The evidence ids it cites name artifacts that are not on this machine, and every criterion below is decidable from the text you have been given — a claim that contradicts its own stated resolution, a remedy framed as the only one, or an implementation specific restated as a general rule are all visible here.' \
		'RUBRIC — you MUST return a score in [0,1] for EVERY criterion listed. Omitting one makes the whole panel UNJUDGED and the candidate is re-judged at full cost, so an omission prevents a verdict rather than softening it. If you cannot assess one, say so and score your honest worst case.' \
		"$criteria" \
		'Return EXACTLY one JSON object as your final message, no prose around it:' \
		'{"score": <0..1>, "passed": <true|false>, "judge_type": "standard|adversarial", "feedback_summary": "<why>", "criterion_scores": {<each criterion>: <0..1>}}'
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

	local prompt model
	prompt=$(librarian_lesson_auto_judge_prompt "$candidate" "$rubric")
	[[ -z "$prompt" ]] && { printf 'unavailable'; return 0; }
	model=$(librarian_config_get '.librarian.lesson_auto.judge_model' 2>/dev/null)
	case "$model" in ''|null) model="claude-haiku-4-5-20251001" ;; esac

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
	# Was a `case ''|null)` fallback -- a fourth spelling of the same idiom,
	# and just as blind to a non-numeric value (ONL-132).
	cap=$(librarian_config_int '.librarian.lesson_auto.max_juries_per_scan' 1 2>/dev/null)

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

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
# What is judged is the claim, because the claim is what gets promoted. The
# model sees the whole candidate, and until ONL-187 the prompt never said which
# part it was judging: all three false refusals in the 2026-10-22 record
# (docs/measurements/2026-10-22-false-refusals) refused a general claim over a
# rationale that cited this repo's plugins. The rationale still counts, as
# evidence that the claim holds only for some version.
#
# Usage: librarian_lesson_auto_justify <candidate_json> [model]
#
# The instructions are _librarian_lesson_auto_justify_preamble, kept apart
# from the candidate so a refusal can be fingerprinted against exactly the
# text that produced it (ONL-112).
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
		_librarian_lesson_auto_justify_preamble
		printf '%s\n' '<candidate>'
		printf '%s' "$candidate" | jq -r '"claim: \(.claim)\nrationale: \(.rationale)\nresolution: \(.evidence.resolution)\nstack: \(.applies_to.stack | join(", "))"' 2>/dev/null
		printf '%s\n' '</candidate>'
	} > "$prompt_file" || { rm -f "$prompt_file"; return 0; }

	local args=(-p --max-turns 1 --settings '{"disableAllHooks":true}')
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

# Everything the justification prompt says before the candidate.
_librarian_lesson_auto_justify_preamble() {
	printf '%s\n' 'You are deciding whether a lesson holds regardless of version.'
	printf '%s\n' 'Output ONE sentence, or REFUSE: followed by ONE sentence saying why.'
	printf '%s\n\n' 'No markdown, no preamble.'
	printf '%s\n' 'Judge the claim line, as written. Do not restate it as a more general'
	printf '%s\n' 'principle and judge that instead. A claim that names a project'"'"'s own'
	printf '%s\n' 'plugin, helper or internal mechanism is project-specific: refuse it.'
	printf '%s\n' 'The rationale, resolution and stack are evidence about the claim, not'
	printf '%s\n' 'what is being judged. A rationale that cites a specific project, plugin'
	printf '%s\n' 'or helper records where the lesson was learned, and that is not by'
	printf '%s\n' 'itself a reason to refuse. Refuse on the evidence only when it shows the'
	printf '%s\n\n' 'claim itself depends on a version.'
	printf '%s\n' 'Refuse unless the claim is true independent of any version of any'
	printf '%s\n\n' 'tool named in its stack.'
	printf '%s\n' 'Two things make a justification wrong, and both are refusals:'
	printf '%s\n' '- asserting one remedy is required when other standard remedies exist'
	printf '%s\n\n' '- claiming anything the cited evidence does not actually show'
	printf '%s\n' 'Write why this lesson holds regardless of version:'
}

# Identify the question a refusal answered: the prompt's instructions and the
# model that read them (ONL-112). A refusal is held only while both are
# unchanged, so a rewritten prompt (as ONL-187 did) or a different model
# re-asks each refused candidate once instead of trusting an answer to a
# question nobody is asking any more. librarian_body_hash normalizes case and
# whitespace, so reflowing the prompt does not re-bill anything.
#
# Usage: librarian_lesson_auto_justify_fingerprint [model]
librarian_lesson_auto_justify_fingerprint() {
	librarian_body_hash "$(_librarian_lesson_auto_justify_preamble)
model: ${1:-}"
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
# The fingerprint is what holds the refusal against the next scan; see
# librarian_lesson_auto_justify_fingerprint.
#
# Usage: _librarian_lesson_auto_record_refusal <proposal_path> <response> <fingerprint>
_librarian_lesson_auto_record_refusal() {
	local path="$1" response="$2" fingerprint="${3:-}"
	local reason now updated
	reason=$(printf '%s' "$response" | sed -E 's/^REFUSE[[:space:]]*:?[[:space:]]*//')
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(jq --arg r "$reason" --arg at "$now" --arg f "$fingerprint" \
		'.auto_refusal = {reason: (if $r == "" then null else $r end), refused_at: $at}
		 + (if $f == "" then {} else {fingerprint: $f} end)' \
		"$path" 2>/dev/null) || return 0
	librarian_lesson_write_atomic "$path" "$updated" >/dev/null 2>&1 || true
}

# Record why promote refused a lesson the jury just judged (ONL-220). The
# verdict is already on disk, so the lesson is stranded until someone runs
# `lessons promote <id>`, and promote's stderr is the only account of why. No
# person is present to read it, so it goes on the envelope, where `lessons
# show` prints it. Promote's stamp clears it on a later success. Best effort,
# like the refusal record above: a failed write leaves the lesson stranded
# exactly as before, and still counted at SessionStart.
#
# Usage: _librarian_lesson_auto_record_promote_error <proposal_path> <stderr>
_librarian_lesson_auto_record_promote_error() {
	local path="$1" reason="${2:-}"
	local now updated
	now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
	updated=$(jq --arg r "$reason" --arg at "$now" \
		'.promote_error = {reason: (if $r == "" then null else $r end), refused_at: $at}' \
		"$path" 2>/dev/null) || return 0
	librarian_lesson_write_atomic "$path" "$updated" >/dev/null 2>&1 || true
}

# Announce the model's answer for one parked candidate (ONL-116). On a
# refusal, only whether a reason was given rides on the bus; the reason itself
# is on the proposal, recorded by _librarian_lesson_auto_record_refusal.
#
# Usage: _librarian_lesson_auto_emit_asserted <lesson_id> <outcome> [response]
_librarian_lesson_auto_emit_asserted() {
	local id="$1" outcome="$2" response="${3:-}" payload
	if [[ "$outcome" == "refused" ]]; then
		local reason
		reason=$(printf '%s' "$response" | sed -E 's/^REFUSE[[:space:]]*:?[[:space:]]*//')
		payload=$(jq -cn --arg id "$id" --argjson g "$([[ -n "$reason" ]] && echo true || echo false)" \
			'{lesson_id: $id, outcome: "refused", reason_given: $g}')
	else
		payload=$(jq -cn --arg id "$id" --arg o "$outcome" '{lesson_id: $id, outcome: $o}')
	fi
	librarian_lesson_emit "librarian.lesson.asserted" "$payload"
}

# Auto-confirm one parked candidate. Prints exactly one of:
#   confirmed:<id>             model asserted a scope; now awaiting a jury
#   skipped:not_parked         scope is not unscoped; nothing to assert
#   skipped:no_justification   the model refused; left pending for a human,
#                              with the refusal recorded as .auto_refusal
#   skipped:held               a person deferred or unconfirmed it (.auto_hold)
#   skipped:refused            already refused by this prompt and model
#   unavailable                infrastructure, or a lesson_auto.visibility
#                              confirm would refuse; nothing written
#
# The two skips are what keep this loop from re-billing the same refusal on
# every scan and from undoing a person's "not now" (ONL-112). Neither asks
# the model, so neither emits librarian.lesson.asserted.
#
# Every outcome but skipped:not_parked emits librarian.lesson.asserted. A
# candidate that is not parked was never a question for the model.
#
# Usage: librarian_lesson_auto_confirm_one <key> <lesson_id>
librarian_lesson_auto_confirm_one() {
	local key="$1"
	local lesson_id="$2"
	[[ -z "$key" || -z "$lesson_id" ]] && { printf 'unavailable'; return 0; }

	local path candidate
	path="$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json"
	[[ -f "$path" ]] || { _librarian_lesson_auto_emit_asserted "$lesson_id" unavailable; printf 'unavailable'; return 0; }
	candidate=$(jq -c '.candidate' "$path" 2>/dev/null) \
		|| { _librarian_lesson_auto_emit_asserted "$lesson_id" unavailable; printf 'unavailable'; return 0; }

	if ! printf '%s' "$candidate" | jq -e '.applies_to.scope.kind == "unscoped"' >/dev/null 2>&1; then
		printf 'skipped:not_parked'
		return 0
	fi

	if jq -e 'has("auto_hold")' "$path" >/dev/null 2>&1; then
		printf 'skipped:held'
		return 0
	fi

	# Checked before the model call, not after: librarian_lesson_confirm refuses
	# a justification at private visibility, so a misconfigured value used to
	# pay for an answer that could never be written, on every scan.
	local visibility
	visibility=$(librarian_config_get '.librarian.lesson_auto.visibility' 2>/dev/null)
	case "$visibility" in ''|null) visibility="org" ;; esac
	case "$visibility" in
		org | public) ;;
		*) _librarian_lesson_auto_emit_asserted "$lesson_id" unavailable; printf 'unavailable'; return 0 ;;
	esac

	local model fingerprint justification
	model=$(librarian_config_get '.librarian.lesson_transform.model' 2>/dev/null)
	case "$model" in null) model="" ;; esac
	fingerprint=$(librarian_lesson_auto_justify_fingerprint "$model")
	if [[ -n "$fingerprint" ]] && jq -e --arg f "$fingerprint" \
		'.auto_refusal.fingerprint == $f' "$path" >/dev/null 2>&1; then
		printf 'skipped:refused'
		return 0
	fi

	justification=$(librarian_lesson_auto_justify "$candidate" "$model")

	# Empty is infrastructure, not a verdict — the same distinction
	# librarian_lesson_transform_one draws. Leave the artifact untouched.
	[[ -z "$justification" ]] && { _librarian_lesson_auto_emit_asserted "$lesson_id" unavailable; printf 'unavailable'; return 0; }
	if [[ "$justification" == REFUSE* ]]; then
		_librarian_lesson_auto_record_refusal "$path" "$justification" "$fingerprint"
		_librarian_lesson_auto_emit_asserted "$lesson_id" refused "$justification"
		printf 'skipped:no_justification'
		return 0
	fi

	librarian_lesson_confirm "$key" "$lesson_id" "$visibility" "$justification" model \
		>/dev/null 2>&1 || { _librarian_lesson_auto_emit_asserted "$lesson_id" unavailable; printf 'unavailable'; return 0; }
	_librarian_lesson_auto_emit_asserted "$lesson_id" asserted
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

	local args=(-p --max-turns "$_LIBRARIAN_LESSON_JUDGE_MAX_TURNS" --agent "$agent" --settings '{"disableAllHooks":true}')
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
	local promote_err
	case "$rc" in
		0) promote_err=$(librarian_lesson_promote "$key" "$lesson_id" 2>&1 >/dev/null) \
		   	|| _librarian_lesson_auto_record_promote_error \
		   		"$(librarian_lessons_dir "$key")/proposals/${lesson_id}.json" "$promote_err"
		   printf 'judged:%s' "$lesson_id" ;;
		2) printf 'skipped:unjudged' ;;
		*) printf 'unavailable' ;;
	esac
}

# Auto-confirm every parked candidate, then jury as many as the cap allows.
# A no-op unless lesson_auto.enabled is true, and then it emits nothing, so a
# scan with no librarian.autojury.complete is a scan where the stage was off.
#
# session_id attributes every event the stage causes, including the verdicts
# and promotions emitted deeper down. LIBRARIAN_SESSION_ID is declared local
# here, so bash's dynamic scope hands it to every callee and nothing leaks
# past the stage.
#
# Usage: librarian_lesson_auto_stage <key> [session_id]
librarian_lesson_auto_stage() {
	local key="$1"
	[[ -z "$key" ]] && return 0
	local LIBRARIAN_SESSION_ID="${2:-${LIBRARIAN_SESSION_ID:-}}"

	local enabled
	enabled=$(librarian_config_get '.librarian.lesson_auto.enabled' 2>/dev/null)
	[[ "$enabled" != "true" ]] && return 0

	local cap
	# Was a `case ''|null)` fallback -- a fourth spelling of the same idiom,
	# and just as blind to a non-numeric value (ONL-132).
	cap=$(librarian_config_int '.librarian.lesson_auto.max_juries_per_scan' 1 2>/dev/null)

	local started_ms
	started_ms=$(_librarian_lesson_now_ms)

	local id result asserted=0 refused=0 unavailable=0
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		result=$(librarian_lesson_auto_confirm_one "$key" "$id")
		case "$result" in
			confirmed:*) asserted=$((asserted + 1)) ;;
			skipped:no_justification) refused=$((refused + 1)) ;;
			unavailable) unavailable=$((unavailable + 1)) ;;
		esac
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
	#
	# The loop runs past the cap instead of breaking, only to count what the
	# cap deferred: a backlog the cap keeps growing is the cost signal ONL-115
	# has to see.
	local juried=0 deferred=0
	while IFS= read -r id; do
		[[ -z "$id" ]] && continue
		local proposal_path asserted_by
		proposal_path="$(librarian_lessons_dir "$key")/proposals/${id}.json"
		asserted_by=$(jq -r '.asserted_by // "human"' "$proposal_path" 2>/dev/null)
		[[ "$asserted_by" != "model" ]] && continue
		if [[ "$juried" -ge "$cap" ]]; then
			deferred=$((deferred + 1))
			continue
		fi
		librarian_lesson_auto_judge_one "$key" "$id" >/dev/null
		juried=$((juried + 1))
	done < <(librarian_lesson_list_by_status "$key" confirmed | jq -r '.[].id' 2>/dev/null)

	local duration_ms
	duration_ms=$(( $(_librarian_lesson_now_ms) - started_ms ))
	[[ "$duration_ms" -ge 0 ]] || duration_ms=0
	librarian_lesson_emit "librarian.autojury.complete" "$(jq -cn \
		--argjson asserted "$asserted" --argjson refused "$refused" \
		--argjson unavailable "$unavailable" --argjson juried "$juried" \
		--argjson deferred "$deferred" --argjson duration_ms "$duration_ms" \
		'{asserted: $asserted, refused: $refused, unavailable: $unavailable,
		  juried: $juried, deferred_by_cap: $deferred, duration_ms: $duration_ms}')"

	return 0
}

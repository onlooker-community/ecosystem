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

#!/usr/bin/env bash
# Lesson transform — librarian's fifth stage.
#
# Reads one durable, classified, deduped archivist artifact and emits a lesson
# candidate: the four fields inferable from an artifact (claim, rationale,
# evidence, applies_to). The other nine required Lesson fields belong to later
# stages, so this never produces a schema-complete Lesson and cannot be
# validated against the full lesson schema.
#
# Requires librarian-lesson-validate.sh and librarian-lesson-storage.sh.

_LIBRARIAN_LESSON_TIMEOUT_SECONDS="${_LIBRARIAN_LESSON_TIMEOUT_SECONDS:-20}"

# Usage: librarian_lesson_build_prompt <artifact_json>
librarian_lesson_build_prompt() {
	local artifact="$1"
	local summary detail files_list artifact_id session_id project_key created_at

	summary=$(printf '%s' "$artifact" | jq -r '.summary // ""')
	detail=$(printf '%s' "$artifact" | jq -r '.detail // ""')
	files_list=$(printf '%s' "$artifact" | jq -r '(.files // []) | join(", ")')
	artifact_id=$(printf '%s' "$artifact" | jq -r '.id // ""')
	session_id=$(printf '%s' "$artifact" | jq -r '.session_id // ""')
	project_key=$(printf '%s' "$artifact" | jq -r '.project_key // ""')
	created_at=$(printf '%s' "$artifact" | jq -r '.created_at // ""')

	cat <<EOF
You are turning a session artifact into a shareable lesson, or refusing to.

A lesson states something that was learned, why it follows, and the exact
version range in which it holds. It is shared with other people, so a wrong
lesson actively misleads. Refusing is the safe answer.

Output ONLY one JSON object on one line. No markdown fences, no prose.

REFUSE when either is true, by outputting exactly:
  { "eligible": false, "reason": "no_resolution" }
  { "eligible": false, "reason": "no_versions" }

- "no_resolution": the artifact records a problem but not what resolved it.
  "This breaks" without "and this fixed it" is a warning, not a lesson.
  Never invent a resolution that is not in the artifact.
- "no_versions": you cannot determine which versions the claim is bound to.

Otherwise output:
{
  "claim": "<what was learned, one sentence>",
  "rationale": "<why the claim follows from the evidence>",
  "evidence": { "resolution": "<what actually resolved it, from the artifact>" },
  "applies_to": {
    "stack": ["<tool or package name>", ...],
    "scope": { "kind": "versioned", "versions": { "<stack entry>": "<range>" } },
    "file_patterns": [],
    "task_kinds": []
  }
}

VERSION RANGE RULES — these are strict and a violation is discarded:
- Allowed: "<6", "<=6", "=6", ">4", ">=4", or two-sided ">=4 <6".
- FORBIDDEN: npm syntax. Never "^5.4.21", "~5", "5.x", or a bare "5.4.21".
- FORBIDDEN: ">=0", ">=0.0", ">=0.0.0". An unbounded lower bound matches
  everything and would never expire.
- Every key in versions MUST also appear in stack.
- Generalize honestly. Observing a break on vite 5.4.21 with vitest 4.1.9
  supports {"vite": "<6", "vitest": ">=4"} only if the cause is the missing
  API rather than that exact build.

There is no version-independent option. If the claim is not bound to a
version range, refuse with "no_versions".

<artifact>
id: ${artifact_id}
summary: ${summary}
detail: ${detail}
files: ${files_list}
project_key: ${project_key}
session_id: ${session_id}
created_at: ${created_at}
</artifact>
EOF
}

# Call the model. Prints raw output, or empty string on ANY infrastructure
# failure — missing CLI, timeout, empty response. Empty means "could not
# judge", which is not a verdict.
#
# Usage: librarian_lesson_call <artifact_json> <model>
librarian_lesson_call() {
	local artifact="$1"
	local model="${2:-}"

	command -v claude >/dev/null 2>&1 || return 0
	[[ -z "$artifact" ]] && return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-lesson.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-lesson.$$"
	# shellcheck disable=SC2064
	trap "rm -f '$prompt_file'" EXIT

	librarian_lesson_build_prompt "$artifact" > "$prompt_file" || return 0

	local args=(-p --max-turns 1)
	[[ -n "$model" ]] && args+=(--model "$model")

	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$_LIBRARIAN_LESSON_TIMEOUT_SECONDS" \
			claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$_LIBRARIAN_LESSON_TIMEOUT_SECONDS" \
			claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi

	rm -f "$prompt_file"
	trap - EXIT

	[[ -z "$response" ]] && return 0
	printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//'
}

# Transform one artifact. Always exits 0. Prints exactly one of:
#   proposed:<ulid>       candidate written
#   declined:<reason>     a real verdict, recorded in declined.jsonl
#   skipped:pregate       no version token; free to redo, nothing recorded
#   skipped:seen          already handled
#   unavailable           infrastructure failure; nothing recorded
#
# Usage: librarian_lesson_transform_one <key> <artifact_json>
librarian_lesson_transform_one() {
	local key="$1"
	local artifact="$2"
	[[ -z "$key" || -z "$artifact" ]] && { printf 'unavailable'; return 0; }

	local artifact_id session_id project_key created_at
	artifact_id=$(printf '%s' "$artifact" | jq -r '.id // ""')
	session_id=$(printf '%s' "$artifact" | jq -r '.session_id // ""')
	project_key=$(printf '%s' "$artifact" | jq -r '.project_key // ""')
	created_at=$(printf '%s' "$artifact" | jq -r '.created_at // ""')
	[[ -z "$artifact_id" ]] && { printf 'unavailable'; return 0; }

	if librarian_lesson_seen "$key" "$artifact_id"; then
		printf 'skipped:seen'
		return 0
	fi

	if ! librarian_lesson_pregate "$artifact"; then
		printf 'skipped:pregate'
		return 0
	fi

	local model raw
	model=$(librarian_config_get '.librarian.lesson_transform.model')

	raw=$(librarian_lesson_call "$artifact" "$model")

	# Empty means infrastructure, not verdict. Leave the artifact untouched.
	if [[ -z "$raw" ]]; then
		printf 'unavailable'
		return 0
	fi

	if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
		librarian_lesson_append_declined "$key" "$artifact_id" "transform_invalid"
		printf 'declined:transform_invalid'
		return 0
	fi

	# An explicit refusal is a real answer. Checked with jq -e rather than a
	# `// empty` string capture: jq's // operator treats JSON `false` as
	# falsy, same as null, so `.eligible // empty` silently discards a real
	# `"eligible": false` refusal instead of reporting it.
	local reason
	if printf '%s' "$raw" | jq -e '.eligible == false' >/dev/null 2>&1; then
		reason=$(printf '%s' "$raw" | jq -r '.reason // "transform_invalid"')
		case "$reason" in
			no_resolution|no_versions) ;;
			*) reason="transform_invalid" ;;
		esac
		librarian_lesson_append_declined "$key" "$artifact_id" "$reason"
		printf 'declined:%s' "$reason"
		return 0
	fi

	# Stitch in the provenance the model is not asked to produce.
	local candidate
	candidate=$(printf '%s' "$raw" | jq -c \
		--arg aid "$artifact_id" \
		--arg sid "$session_id" \
		--arg pk "$project_key" \
		--arg at "$created_at" \
		'.evidence.artifact_ids = [$aid]
		 | .evidence.session_ids = [$sid]
		 | .evidence.project_key = $pk
		 | .evidence.observed_at = $at' 2>/dev/null) || candidate=""

	if [[ -z "$candidate" ]]; then
		librarian_lesson_append_declined "$key" "$artifact_id" "transform_invalid"
		printf 'declined:transform_invalid'
		return 0
	fi

	if ! librarian_lesson_validate_candidate "$candidate" 2>/dev/null; then
		librarian_lesson_append_declined "$key" "$artifact_id" "schema_invalid"
		printf 'declined:schema_invalid'
		return 0
	fi

	local id
	id=$(librarian_lesson_write_proposal "$key" "$candidate" "$artifact_id") || {
		printf 'unavailable'
		return 0
	}
	printf 'proposed:%s' "$id"
}

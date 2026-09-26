#!/usr/bin/env bash
# Lesson transform — librarian's fifth stage.
#
# Reads one durable, classified, deduped archivist artifact and emits a lesson
# candidate: the four fields inferable from an artifact (claim, rationale,
# evidence, applies_to). The other nine required Lesson fields belong to later
# stages, so this never produces a schema-complete Lesson and cannot be
# validated against the full lesson schema.
#
# Requires librarian-lesson-validate.sh, librarian-lesson-storage.sh, and
# librarian-config.sh (librarian_config_get).
#
# Config inputs (read via librarian_config_get from librarian_lesson_call):
#   librarian.lesson_transform.model              Anthropic model id
#   librarian.lesson_transform.timeout_seconds    Per-call wall-clock ceiling
#
# timeout_seconds bounds one call, not a scan. The aggregate ceiling across a
# whole SessionEnd is librarian.lesson_transform.total_budget_ms, enforced by
# the caller in librarian-session-end.sh — a per-call timeout alone leaves
# KEPT_COUNT of them unbounded end to end (ecosystem-qwi).

# Fallback when config hasn't been loaded or leaves the key unset.
_LIBRARIAN_LESSON_DEFAULT_TIMEOUT_SECONDS=20

# Cap on how much of a response the JSON-object extractor will scan. The
# scanner is a per-character bash loop — effectively O(n^2) on long input,
# since bash string slicing on a long string isn't O(1) per call — and it
# runs after the claude call, uncapped, inside a SessionEnd hook that must
# not stall session end. `claude -p` has no output-size flag to bound the
# response itself, so the bound is enforced here instead. A response that
# exceeds this without yielding valid JSON in the scanned prefix has not
# followed the "output ONLY a single JSON object on one line" instruction
# anyway, so declining it is correct, not just expedient.
_LIBRARIAN_LESSON_EXTRACT_MAX_CHARS=8192

# Usage: librarian_lesson_build_prompt <artifact_json> [mode]
#
# mode is "versioned" (default) or "unscoped", chosen by the caller from
# librarian_lesson_pregate. The two differ in one section only: whether a claim
# that cannot be bound to a version range is refused or parked for a human.
librarian_lesson_build_prompt() {
	local artifact="$1"
	local mode="${2:-versioned}"
	local summary detail files_list artifact_id session_id project_key created_at

	summary=$(printf '%s' "$artifact" | jq -r '.summary // ""')
	detail=$(printf '%s' "$artifact" | jq -r '.detail // ""')
	files_list=$(printf '%s' "$artifact" | jq -r '(.files // []) | join(", ")')
	artifact_id=$(printf '%s' "$artifact" | jq -r '.id // ""')
	session_id=$(printf '%s' "$artifact" | jq -r '.session_id // ""')
	project_key=$(printf '%s' "$artifact" | jq -r '.project_key // ""')
	created_at=$(printf '%s' "$artifact" | jq -r '.created_at // ""')

	local scope_rules
	if [[ "$mode" == "unscoped" ]]; then
		# No version token anywhere in the artifact, so asking for a range
		# would only invite invention. The model states the claim and leaves
		# the scope open; a human decides whether it truly holds regardless of
		# version, and a jury checks that. no_versions is unreachable in this
		# mode by construction — there is nothing to refuse for.
		scope_rules='SCOPE — this artifact carries no version information.
Do NOT invent a version range. Output scope exactly:
  "scope": { "kind": "unscoped" }
The scope object must contain nothing but that one key. A human will decide
whether this lesson holds regardless of version; you are not asserting that.

Refuse ONLY with "no_resolution" if the artifact records a problem but not
what resolved it.'
	else
		scope_rules='SCOPE — VERSION RANGE RULES, strict, a violation is discarded:
  "scope": { "kind": "versioned", "versions": { "<stack entry>": "<range>" } }
- Allowed: "<6", "<=6", "=6", ">4", ">=4", or two-sided ">=4 <6".
- FORBIDDEN: npm syntax. Never "^5.4.21", "~5", "5.x", or a bare "5.4.21".
- FORBIDDEN: ">=0", ">=0.0", ">=0.0.0". An unbounded lower bound matches
  everything and would never expire.
- Every key in versions MUST also appear in stack.
- Generalize honestly. Observing a break on vite 5.4.21 with vitest 4.1.9
  supports {"vite": "<6", "vitest": ">=4"} only if the cause is the missing
  API rather than that exact build.

There is no version-independent option. If the claim is not bound to a
version range, refuse with "no_versions".'
	fi

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
    "stack": ["<tool or package name>", "<another tool or package name>"],
    "scope": <exactly as the SCOPE section below directs>,
    "file_patterns": [],
    "task_kinds": []
  }
}

${scope_rules}

<scope-mode>${mode}</scope-mode>
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

# Extract the first balanced top-level JSON object from a string that may
# carry surrounding prose ("Here is the JSON: {...}"). Prints the substring
# on success, prints nothing and returns 1 on failure. Depth-tracks braces
# while skipping ones inside string literals (honoring backslash escapes),
# so a claim like `{"claim": "uses \"quotes\" and { in prose"}` still
# extracts correctly.
#
# Prose wrapping is not the same failure as unparseable output: a model that
# added a sentence around otherwise-valid JSON would very likely produce
# clean JSON on a resample, so declining it as transform_invalid would bury
# a good artifact over formatting noise rather than a real judgment problem.
#
# Usage: _librarian_lesson_extract_json_object <text>
_librarian_lesson_extract_json_object() {
	local text="$1"
	local start=-1 depth=0 in_string=0 escape=0
	local i len ch

	len=${#text}
	for (( i = 0; i < len; i++ )); do
		ch="${text:i:1}"
		if [[ $start -eq -1 ]]; then
			[[ "$ch" == "{" ]] && { start=$i; depth=1; }
			continue
		fi
		if [[ $escape -eq 1 ]]; then
			escape=0
			continue
		fi
		case "$ch" in
			'\') [[ $in_string -eq 1 ]] && escape=1 ;;
			'"') in_string=$((1 - in_string)) ;;
			'{') [[ $in_string -eq 0 ]] && depth=$((depth + 1)) ;;
			'}')
				if [[ $in_string -eq 0 ]]; then
					depth=$((depth - 1))
					if [[ $depth -eq 0 ]]; then
						printf '%s' "${text:start:i-start+1}"
						return 0
					fi
				fi
				;;
		esac
	done

	return 1
}

# Call the model. Prints raw output, or empty string on ANY infrastructure
# failure — missing CLI, timeout, empty response. Empty means "could not
# judge", which is not a verdict.
#
# Usage: librarian_lesson_call <artifact_json> <model>
librarian_lesson_call() {
	local artifact="$1"
	local model="${2:-}"
	local mode="${3:-versioned}"

	command -v claude >/dev/null 2>&1 || return 0
	[[ -z "$artifact" ]] && return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-lesson.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-lesson.$$"
	# shellcheck disable=SC2064
	trap "rm -f '$prompt_file'" EXIT

	librarian_lesson_build_prompt "$artifact" "$mode" > "$prompt_file" || return 0

	local args=(-p --max-turns 1)
	[[ -n "$model" ]] && args+=(--model "$model")

	local timeout_seconds
	timeout_seconds=$(librarian_config_get '.librarian.lesson_transform.timeout_seconds' 2>/dev/null)
	[[ -z "$timeout_seconds" || "$timeout_seconds" == "null" ]] \
		&& timeout_seconds="$_LIBRARIAN_LESSON_DEFAULT_TIMEOUT_SECONDS"

	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$timeout_seconds" \
			claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$timeout_seconds" \
			claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi

	rm -f "$prompt_file"
	trap - EXIT

	[[ -z "$response" ]] && return 0

	local cleaned
	cleaned=$(printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')

	# Fast path: the response is already valid JSON on its own.
	if printf '%s' "$cleaned" | jq -e . >/dev/null 2>&1; then
		printf '%s' "$cleaned"
		return 0
	fi

	# Slow path: pull the first balanced JSON object out of surrounding
	# prose. Bounded to a fixed prefix (see _LIBRARIAN_LESSON_EXTRACT_MAX_CHARS)
	# so a rambling, arbitrarily long response can't turn the O(n^2) scan
	# into an unbounded stall. Only used when it actually recovers valid
	# JSON — otherwise fall through to the original text so the
	# unparseable case still declines.
	local extracted
	extracted=$(_librarian_lesson_extract_json_object \
		"${cleaned:0:_LIBRARIAN_LESSON_EXTRACT_MAX_CHARS}")
	if [[ -n "$extracted" ]] && printf '%s' "$extracted" | jq -e . >/dev/null 2>&1; then
		printf '%s' "$extracted"
		return 0
	fi

	printf '%s' "$cleaned"
}

# Transform one artifact. Always exits 0. Prints exactly one of:
#   proposed:<ulid>       candidate written
#   proposed:<ulid>:unscoped  a PARKED candidate, awaiting a human's scope
#   declined:<reason>     a real verdict, recorded in declined.jsonl
#   skipped:seen          already handled
#   skipped:unscoped_cap  cost control; nothing recorded, so it comes back
#   unavailable           infrastructure failure; nothing recorded
#
# Usage: librarian_lesson_transform_one <key> <artifact_json> [unscoped_so_far] [forced_mode]
#
# unscoped_so_far is how many artifacts this scan has already routed to the
# unscoped path. The caller owns the count, so this function keeps no
# cross-invocation state and the cap stays directly testable. Omitted, it
# defaults to 0, so a direct caller gets one parked candidate and no surprise.
#
# forced_mode skips the pre-gate. Only "unscoped" is accepted, and only
# reconsider passes it: an artifact already declined no_versions is by
# construction one that PASSED the pre-gate — that is how it reached the model
# to be refused — so replaying it would route versioned and be refused again.
# The decline record is the evidence that route already failed on this artifact,
# which is what earns skipping the gate rather than second-guessing it.
librarian_lesson_transform_one() {
	local key="$1"
	local artifact="$2"
	local unscoped_so_far="${3:-0}"
	local forced_mode="${4:-}"
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

	# The pre-gate routes, it does not gate. A version-shaped token means a
	# range is plausibly bindable, so ask for one; its absence means asking
	# would invite invention, so park the claim for a human instead. Nothing is
	# dropped without a record any more — see ONL-107.
	local mode="versioned"
	if [[ "$forced_mode" == "unscoped" ]]; then
		mode="unscoped"
	else
		librarian_lesson_pregate "$artifact" || mode="unscoped"
	fi

	if [[ "$mode" == "unscoped" ]]; then
		local unscoped_cap
		unscoped_cap=$(librarian_config_get '.librarian.lesson_transform.unscoped_per_scan' 2>/dev/null)
		[[ -z "$unscoped_cap" || "$unscoped_cap" == "null" ]] && unscoped_cap=3
		if [[ "$unscoped_so_far" -ge "$unscoped_cap" ]]; then
			# Deliberately writes NO decline record. A decline is terminal
			# (librarian_lesson_seen reads declined.jsonl), so recording one for
			# a cost-control skip would destroy the candidate permanently.
			# Skipping means the artifact is reconsidered on a later scan, which
			# is the direction this stage already treats as safe.
			printf 'skipped:unscoped_cap'
			return 0
		fi
	fi

	local model raw
	model=$(librarian_config_get '.librarian.lesson_transform.model')

	raw=$(librarian_lesson_call "$artifact" "$model" "$mode")

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

	# The route rides on stdout because it has to: this function is called
	# inside a command substitution, so a variable it exported could not reach
	# the worker's loop. `proposed:*` still matches both forms, so no existing
	# caller or matcher breaks — but anything extracting the id has to strip
	# twice for a parked result.
	if [[ "$mode" == "unscoped" ]]; then
		printf 'proposed:%s:unscoped' "$id"
	else
		printf 'proposed:%s' "$id"
	fi
}

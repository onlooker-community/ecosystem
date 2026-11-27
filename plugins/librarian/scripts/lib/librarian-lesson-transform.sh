#!/usr/bin/env bash
# Lesson transform — librarian's fifth stage.
#
# Reads one durable, classified, deduped archivist artifact and emits a lesson
# candidate: the four fields inferable from an artifact (claim, rationale,
# evidence, applies_to). The other nine required Lesson fields belong to later
# stages, so this never produces a schema-complete Lesson and cannot be
# validated against the full lesson schema.
#
# Requires librarian-lesson-validate.sh, librarian-lesson-storage.sh,
# librarian-lesson-observe.sh, librarian-lesson-scope.sh, and
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

# Cap on how much of a response the JSON-object extractor will read. It runs
# after the claude call, inside a SessionEnd hook that must not stall session
# end, and hands the remainder of the response to jq once per opening it tries.
# It was a per-character bash loop, effectively O(n^2), until ONL-194; the cap
# predates that and still bounds every attempt's input. `claude -p` has no
# output-size flag to bound the response itself, so the bound is enforced here
# instead. A response that
# exceeds this without yielding valid JSON in the scanned prefix has not
# followed the "output ONLY a single JSON object on one line" instruction
# anyway, so declining it is correct, not just expedient.
_LIBRARIAN_LESSON_EXTRACT_MAX_CHARS=8192
# How many plausible openings the extractor hands to jq before giving up. A
# real response has at most one or two prose fragments that open like an object
# before the object itself; eight leaves room for that while bounding the jq
# processes a response full of `{"` fragments can cost.
_LIBRARIAN_LESSON_EXTRACT_MAX_ATTEMPTS=8

# Usage: librarian_lesson_build_prompt <artifact_json>
#
# The model names the stack and the topics. It is never asked for a version or
# a scope: versions are read from the project by librarian_lesson_observe.
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

A lesson states something that was learned, why it follows, and which tools
it depends on. It is shared with other people, so a wrong
lesson actively misleads. Refusing is the safe answer.

Output ONLY one JSON object on one line. No markdown fences, no prose.

REFUSE when the following is true, by outputting exactly:
  { "eligible": false, "reason": "no_resolution" }

- "no_resolution": the artifact records a problem but not what resolved it.
  "This breaks" without "and this fixed it" is a warning, not a lesson.
  Never invent a resolution that is not in the artifact.

Otherwise output:
{
  "claim": "<what was learned, one sentence>",
  "rationale": "<why the claim follows from the evidence>",
  "evidence": { "resolution": "<what actually resolved it, from the artifact>" },
  "applies_to": {
    "stack": ["<a package, CLI or service the claim depends on>"],
    "topics": ["<a concept the lesson is about>"],
    "file_patterns": [],
    "task_kinds": []
  }
}

CLAIM RULES — a judge checks each of these against the artifact:
- One fix that worked is not the only fix. Do not write "must", "always",
  "only" or "never" about a remedy unless the artifact shows the alternatives
  failing. Say what resolved the problem: "X resolves Y", not "Y must use X".
- Every assertion in claim and rationale must be checkable against the
  artifact text. Do not add a cause, a mechanism or tool behavior the artifact
  does not state. If the artifact quotes code, a pattern or a command, the
  claim must agree with what it quotes.
- file_patterns is usually []. Add a glob only when the lesson is about a
  kind of file (for example "*.bats"), never one of this project's paths, and
  never a glob broader than the files the artifact names.
- stack lists only things with a version: a package, a CLI, a hosted
  service, or a component. List every one the claim depends on. Concepts
  have no version and go in topics: "CSS", "SQL", "testing",
  "rate-limiting", "authentication", "database migrations", "API design".
  stack is [] only when the claim names no tool at all; that is rare, and
  an empty stack on a claim about a tool is wrong.
- Do not output a scope. Versions are read from the project, not inferred.

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

# Extract the first JSON object from a string that may carry surrounding prose
# ("Here is the JSON: {...}"). Prints the object, compacted, on success; prints
# nothing and returns 1 on failure.
#
# Prose wrapping is not the same failure as unparseable output: a model that
# added a sentence around otherwise-valid JSON would very likely produce
# clean JSON on a resample, so declining it as transform_invalid would bury
# a good artifact over formatting noise rather than a real judgment problem.
#
# Only a brace followed by optional whitespace and `"` is tried, because every
# object worth extracting opens with a key. Most of these lessons are about
# bash, and a model restating one quotes `${v:-N}` and `{a,b}` freely. The
# extractor used to take the first balanced brace pair, which handed the jury
# `{v:-N}`, so every verdict for such a lesson was lost and the candidate was
# re-juried each scan (ONL-194).
#
# jq does the parsing: `input` reads exactly one value from where the opening
# starts and ignores whatever follows it, so strings, escapes and nested braces
# are handled by a real parser, not a hand-rolled scan. An opening jq rejects
# moves on to the next one, up to _LIBRARIAN_LESSON_EXTRACT_MAX_ATTEMPTS times.
#
# Usage: _librarian_lesson_extract_json_object <text>
_librarian_lesson_extract_json_object() {
	local rest="${1:0:_LIBRARIAN_LESSON_EXTRACT_MAX_CHARS}"
	local opening='\{[[:space:]]*"'
	local attempts=0 before object

	while (( attempts < _LIBRARIAN_LESSON_EXTRACT_MAX_ATTEMPTS )); do
		[[ "$rest" =~ $opening ]] || return 1
		before="${rest%%"${BASH_REMATCH[0]}"*}"
		rest="${rest:${#before}}"
		object=$(printf '%s' "$rest" | jq -cn input 2>/dev/null)
		if [[ -n "$object" ]]; then
			printf '%s' "$object"
			return 0
		fi
		rest="${rest:1}"
		attempts=$((attempts + 1))
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

	command -v claude >/dev/null 2>&1 || return 0
	[[ -z "$artifact" ]] && return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-lesson.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-lesson.$$"
	# No EXIT trap for this file. Called directly rather than through $(...), a
	# trap here replaces the caller's and the `trap - EXIT` after it clears it
	# outright, and the classify worker's EXIT trap is what releases its queue
	# lock (ONL-118). Every path out removes the file itself; a killed call
	# leaks one small file under $TMPDIR, which costs nothing next to a lock
	# that blocks its queue for good.
	librarian_lesson_build_prompt "$artifact" > "$prompt_file" \
		|| { rm -f "$prompt_file"; return 0; }

	local args=(-p --max-turns 1 --settings '{"disableAllHooks":true}')
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

	[[ -z "$response" ]] && return 0

	local cleaned
	cleaned=$(printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')

	# Fast path: the response is already valid JSON on its own.
	if printf '%s' "$cleaned" | jq -e . >/dev/null 2>&1; then
		printf '%s' "$cleaned"
		return 0
	fi

	# Slow path: pull the first JSON object out of surrounding prose, reading
	# only a fixed prefix (see _LIBRARIAN_LESSON_EXTRACT_MAX_CHARS). Only used
	# when it actually recovers valid JSON — otherwise fall through to the
	# original text so the unparseable case still declines.
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
#   proposed:<ulid>           candidate written
#   proposed:<ulid>:unscoped  a PARKED candidate: nothing in its stack could be
#                             given a range, so a human decides its scope
#   declined:<reason>         a real verdict, recorded in declined.jsonl;
#                             reason is no_resolution, transform_invalid or
#                             schema_invalid
#   skipped:seen              already handled
#   unavailable               infrastructure failure; nothing recorded
#
# The model writes the claim, the stack and the topics, never a scope. The scope
# is derived: librarian_lesson_observe reads the version of each stack entry
# from the project at the session's commit, and
# librarian_lesson_scope_from_observation turns that into no_stack, versioned
# or unscoped (D4, D5). A scope the model writes anyway is deleted.
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
			no_resolution) ;;
			*) reason="transform_invalid" ;;
		esac
		librarian_lesson_append_declined "$key" "$artifact_id" "$reason"
		printf 'declined:%s' "$reason"
		return 0
	fi

	# A null session_id becomes [], not [""]: commit-mined artifacts have no
	# session (ONL-108), and librarian-classify-worker.sh already writes
	# source_session_ids the same way.
	# Stitch in the provenance the model is not asked to produce.
	local candidate
	candidate=$(printf '%s' "$raw" | jq -c \
		--arg aid "$artifact_id" \
		--arg sid "$session_id" \
		--arg pk "$project_key" \
		--arg at "$created_at" \
		'.evidence.artifact_ids = [$aid]
		 | .evidence.session_ids = (if $sid == "" then [] else [$sid] end)
		 | .evidence.project_key = $pk
		 | .evidence.observed_at = $at
		 # A model-written stack is JSON from a model: keep the non-empty
		 # strings, once each. A stack that is not an array, or whose entries
		 # all fail, is left as written so validation declines it; only a
		 # stack the model wrote as [] may mean "no tool". A scope it wrote
		 # anyway is not its to write.
		 #
		 # All of it only on an object: indexing a string or array applies_to
		 # throws, which declined the candidate transform_invalid while the
		 # same fault in a stack declined schema_invalid. Left as written, a
		 # non-object applies_to is declined by validation, like a bad stack.
		 | if (.applies_to | type) == "object" then
		     (.applies_to.stack // null) as $st
		     | (if ($st | type) == "array"
		          and (($st | length) == 0 or ([$st[] | select(type == "string" and length > 0)] | length) > 0)
		        then .applies_to.stack = ([$st[] | select(type == "string" and length > 0)] | unique)
		        else . end)
		     | .applies_to.topics = ([.applies_to.topics[]? | select(type == "string" and length > 0)] | unique)
		     | del(.applies_to.scope)
		   else . end' 2>/dev/null) || candidate=""

	if [[ -z "$candidate" ]]; then
		librarian_lesson_append_declined "$key" "$artifact_id" "transform_invalid"
		printf 'declined:transform_invalid'
		return 0
	fi

	# Versions are read, not asked for (D2). Observe prints nothing when node
	# is missing or an argument is, and then every entry is unresolved: the
	# candidate stays local rather than failing (D6). A stack that is still
	# malformed here skips this and is declined by validation below.
	local stack observation scope
	if printf '%s' "$candidate" | jq -e '.applies_to.stack | type == "array"' >/dev/null 2>&1 \
		&& printf '%s' "$candidate" | jq -e '.applies_to.stack | all(.[]; type == "string" and length > 0)' >/dev/null 2>&1; then
		stack=$(printf '%s' "$candidate" | jq -c '.applies_to.stack')
		observation=$(librarian_lesson_observe "$project_key" "$created_at" "$stack")
		printf '%s' "$observation" \
			| jq -e '(.observed_on | type == "object") and (.unresolved | type == "array")' >/dev/null 2>&1 \
			|| observation=$(jq -cn --argjson s "$stack" '{observed_on: {}, unresolved: $s}')
		scope=$(librarian_lesson_scope_from_observation "$stack" "$observation")
		candidate=$(printf '%s' "$candidate" | jq -c \
			--argjson o "$observation" --argjson sc "$scope" \
			'.evidence.observed_on = $o.observed_on
			 | .evidence.unresolved = [$o.unresolved[]? | strings]
			 | .applies_to.scope = $sc') || candidate=""

		if [[ -z "$candidate" ]]; then
			librarian_lesson_append_declined "$key" "$artifact_id" "transform_invalid"
			printf 'declined:transform_invalid'
			return 0
		fi
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
	if printf '%s' "$candidate" | jq -e '.applies_to.scope.kind == "unscoped"' >/dev/null 2>&1; then
		printf 'proposed:%s:unscoped' "$id"
	else
		printf 'proposed:%s' "$id"
	fi
}

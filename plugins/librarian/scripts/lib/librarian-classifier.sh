#!/usr/bin/env bash
# Type classifier for librarian candidates.
#
# Calls `claude -p` with a structured prompt that maps a single archivist
# artifact to one of the four memory types (user, feedback, project,
# reference) or null when the artifact is interesting but session-only.
#
# Returns the model's JSON response on stdout, or empty string on any
# error (timeout, missing CLI, invalid JSON, low confidence). Callers
# treat empty as "drop this candidate".
#
# Config inputs (read via librarian_config_get from the caller):
#   librarian.classifier.model              Anthropic model id
#   librarian.classifier.temperature        Sampling temperature
#   librarian.classifier.max_output_tokens  Output cap
#   librarian.classifier.min_classifier_confidence  Drop below this

# Hard wall-clock ceiling for a single classifier call. We never want a
# hung LLM to delay SessionEnd more than this.
_LIBRARIAN_CLASSIFIER_TIMEOUT_SECONDS=20

# Build the classifier prompt for a single artifact.
# Usage: librarian_classifier_build_prompt <artifact_json>
librarian_classifier_build_prompt() {
	local artifact="$1"
	local kind summary detail files_list session_id created_at

	kind=$(printf '%s' "$artifact" | jq -r '.kind // ""')
	summary=$(printf '%s' "$artifact" | jq -r '.summary // ""')
	detail=$(printf '%s' "$artifact" | jq -r '.detail // ""')
	files_list=$(printf '%s' "$artifact" | jq -r '(.files // []) | join(", ")')
	session_id=$(printf '%s' "$artifact" | jq -r '.session_id // ""')
	created_at=$(printf '%s' "$artifact" | jq -r '.created_at // ""')

	cat <<EOF
You are classifying a session artifact for promotion into a long-term memory store.

The store has four types:
- user: durable facts about the user's role, expertise, or working style
- feedback: corrections or validated preferences ("don't do X", "yes, keep doing Y")
- project: ongoing work facts, decisions, constraints not derivable from the code
- reference: pointers to external systems (issue trackers, dashboards, channels)

RULES:
- Output ONLY a single JSON object on one line, no markdown fences, no prose.
- Schema: { "type": "<user|feedback|project|reference|null>",
            "title": "<<=60 chars>",
            "body": "<the memory content; structure per type>",
            "confidence": <float 0-1> }
- Use "type": null when the artifact is interesting but session-only (a
  specific bug fix, a one-off question that got answered, an exploration
  that didn't change anything).
- For feedback and project types, include **Why:** and **How to apply:**
  lines inside the body.

<artifact>
kind: ${kind}
summary: ${summary}
detail: ${detail}
files: ${files_list}
session_id: ${session_id}
created_at: ${created_at}
</artifact>
EOF
}

# Call the classifier for one artifact. Prints the model's JSON output or
# empty string on error.
#
# Usage: librarian_classifier_call <artifact_json> <model> <temperature>
#                                  <max_output_tokens>
librarian_classifier_call() {
	local artifact="$1"
	local model="${2:-}"
	local temperature="${3:-0.2}"
	local max_tokens="${4:-256}"

	command -v claude >/dev/null 2>&1 || return 0
	[[ -z "$artifact" ]] && return 0

	local prompt_file
	prompt_file=$(mktemp -t librarian-classify.XXXXXX 2>/dev/null) \
		|| prompt_file="/tmp/librarian-classify.$$"
	# shellcheck disable=SC2064
	trap "rm -f '$prompt_file'" EXIT

	librarian_classifier_build_prompt "$artifact" > "$prompt_file" || return 0

	local args=(-p --max-turns 1)
	[[ -n "$model" ]] && args+=(--model "$model")

	local response=""
	if command -v timeout >/dev/null 2>&1; then
		response=$(timeout "$_LIBRARIAN_CLASSIFIER_TIMEOUT_SECONDS" \
			claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	elif command -v gtimeout >/dev/null 2>&1; then
		response=$(gtimeout "$_LIBRARIAN_CLASSIFIER_TIMEOUT_SECONDS" \
			claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	else
		response=$(claude "${args[@]}" < "$prompt_file" 2>/dev/null) || response=""
	fi

	rm -f "$prompt_file"
	trap - EXIT

	[[ -z "$response" ]] && return 0

	# Strip accidental markdown fences before parsing.
	local clean
	clean=$(printf '%s' "$response" | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//')

	# Validate the response shape before passing it back.
	if ! printf '%s' "$clean" | jq -e '
		(.type == null or (.type | IN("user", "feedback", "project", "reference")))
		and (.title | type) == "string"
		and (.body | type) == "string"
		and (.confidence | type) == "number"
	' >/dev/null 2>&1; then
		return 0
	fi

	printf '%s' "$clean"
}

# Synthesize a deterministic filename from a classifier result.
# Used when writing accepted promotions into the typed memory store.
# Format: <type>_<slugified-title>.md
#
# Usage: librarian_classifier_filename <type> <title>
librarian_classifier_filename() {
	local type="$1"
	local title="$2"
	local slug
	slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
		| sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g' \
		| cut -c1-60)
	[[ -z "$slug" ]] && slug="memory"
	printf '%s_%s.md' "$type" "$slug"
}
